// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Socket.sol";
import "../src/Notary/AdminNotary.sol";
import "../src/accumulators/SingleAccum.sol";
import "../src/deaccumulators/SingleDeaccum.sol";
import "../src/verifiers/AcceptWithTimeout.sol";
import "../src/examples/counter.sol";

contract HappyTest is Test {
    address constant _socketOwner = address(1);
    address constant _counterOwner = address(2);
    uint256 constant _signerPrivateKey = uint256(3);
    address _signer;
    address constant _raju = address(4);
    address constant _pauser = address(5);
    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct ChainContext {
        uint256 chainId;
        Socket socket__;
        Notary notary__;
        IAccumulator accum__;
        IDeaccumulator deaccum__;
        AcceptWithTimeout verifier__;
        Counter counter__;
    }

    struct MessageContext {
        uint256 amount;
        bytes payload;
        bytes proof;
        uint256 nonce;
        bytes32 root;
        uint256 packetId;
        Signature sig;
    }

    ChainContext _a;
    ChainContext _b;

    function setUp() external {
        _a.chainId = 0x2013AA263;
        _b.chainId = 0x2013AA264;
        _deploySocketContracts();
        _initSigner();
        _deployPlugContracts();
        _configPlugContracts(true);
        _initPausers();
    }

    function testRemoteAddFromAtoB() external {
        uint256 amount = 100;
        bytes memory payload = abi.encode(keccak256("OP_ADD"), amount);
        bytes memory proof = abi.encode(0);

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, amount);
        // TODO: get nonce from event
        (
            bytes32 root,
            uint256 packetId,
            Signature memory sig
        ) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, sig);
        _submitRootOnDst(_a, _b, sig, packetId, root);
        _executePayloadOnDst(_a, _b, packetId, 0, payload, proof);

        assertEq(_b.counter__.counter(), amount);
        assertEq(_a.counter__.counter(), 0);
    }

    function testRemoteAddFromBtoA() external {
        uint256 amount = 100;
        bytes memory payload = abi.encode(keccak256("OP_ADD"), amount);
        bytes memory proof = abi.encode(0);

        hoax(_raju);
        _b.counter__.remoteAddOperation(_a.chainId, amount);
        (
            bytes32 root,
            uint256 packetId,
            Signature memory sig
        ) = _getLatestSignature(_b);
        _submitSignatureOnSrc(_b, sig);
        _submitRootOnDst(_b, _a, sig, packetId, root);
        _executePayloadOnDst(_b, _a, packetId, 0, payload, proof);

        assertEq(_a.counter__.counter(), amount);
        assertEq(_b.counter__.counter(), 0);
    }

    function testRemoteAddAndSubtract() external {
        uint256 addAmount = 100;
        bytes memory addPayload = abi.encode(keccak256("OP_ADD"), addAmount);
        bytes memory addProof = abi.encode(0);
        uint256 addNonce = 0;

        uint256 subAmount = 40;
        bytes memory subPayload = abi.encode(keccak256("OP_SUB"), subAmount);
        bytes memory subProof = abi.encode(0);
        uint256 subNonce = 1;

        bytes32 root;
        uint256 packetId;
        Signature memory sig;

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, addAmount);

        (root, packetId, sig) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, sig);
        _submitRootOnDst(_a, _b, sig, packetId, root);
        _executePayloadOnDst(_a, _b, packetId, addNonce, addPayload, addProof);

        hoax(_raju);
        _a.counter__.remoteSubOperation(_b.chainId, subAmount);

        (root, packetId, sig) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, sig);
        _submitRootOnDst(_a, _b, sig, packetId, root);
        _executePayloadOnDst(_a, _b, packetId, subNonce, subPayload, subProof);

        assertEq(_b.counter__.counter(), addAmount - subAmount);
        assertEq(_a.counter__.counter(), 0);
    }

    function testMessagesOutOfOrderForSequentialConfig() external {
        _configPlugContracts(true);

        MessageContext memory m1;
        m1.amount = 100;
        m1.payload = abi.encode(keccak256("OP_ADD"), m1.amount);
        m1.proof = abi.encode(0);
        m1.nonce = 0;

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, m1.amount);

        (m1.root, m1.packetId, m1.sig) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, m1.sig);
        _submitRootOnDst(_a, _b, m1.sig, m1.packetId, m1.root);

        MessageContext memory m2;
        m2.amount = 40;
        m2.payload = abi.encode(keccak256("OP_ADD"), m2.amount);
        m2.proof = abi.encode(0);
        m2.nonce = 1;

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, m2.amount);

        (m2.root, m2.packetId, m2.sig) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, m2.sig);
        _submitRootOnDst(_a, _b, m2.sig, m2.packetId, m2.root);

        vm.expectRevert(ISocket.InvalidNonce.selector);
        _executePayloadOnDst(
            _a,
            _b,
            m2.packetId,
            m2.nonce,
            m2.payload,
            m2.proof
        );
    }

    function testMessagesOutOfOrderForNonSequentialConfig() external {
        _configPlugContracts(false);

        MessageContext memory m1;
        m1.amount = 100;
        m1.payload = abi.encode(keccak256("OP_ADD"), m1.amount);
        m1.proof = abi.encode(0);
        m1.nonce = 0;

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, m1.amount);

        (m1.root, m1.packetId, m1.sig) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, m1.sig);
        _submitRootOnDst(_a, _b, m1.sig, m1.packetId, m1.root);

        MessageContext memory m2;
        m2.amount = 40;
        m2.payload = abi.encode(keccak256("OP_ADD"), m2.amount);
        m2.proof = abi.encode(0);
        m2.nonce = 1;

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, m2.amount);

        (m2.root, m2.packetId, m2.sig) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, m2.sig);
        _submitRootOnDst(_a, _b, m2.sig, m2.packetId, m2.root);

        _executePayloadOnDst(
            _a,
            _b,
            m2.packetId,
            m2.nonce,
            m2.payload,
            m2.proof
        );
        _executePayloadOnDst(
            _a,
            _b,
            m1.packetId,
            m1.nonce,
            m1.payload,
            m1.proof
        );

        assertEq(_b.counter__.counter(), m1.amount + m2.amount);
        assertEq(_a.counter__.counter(), 0);
    }

    function testExecSameMessageTwice() external {
        uint256 amount = 100;
        bytes memory payload = abi.encode(keccak256("OP_ADD"), amount);
        bytes memory proof = abi.encode(0);

        hoax(_raju);
        _a.counter__.remoteAddOperation(_b.chainId, amount);
        (
            bytes32 root,
            uint256 packetId,
            Signature memory sig
        ) = _getLatestSignature(_a);
        _submitSignatureOnSrc(_a, sig);
        _submitRootOnDst(_a, _b, sig, packetId, root);
        _executePayloadOnDst(_a, _b, packetId, 0, payload, proof);

        vm.expectRevert(ISocket.MessageAlreadyExecuted.selector);
        _executePayloadOnDst(_a, _b, packetId, 0, payload, proof);

        assertEq(_b.counter__.counter(), amount);
        assertEq(_a.counter__.counter(), 0);
    }

    function _deploySocketContracts() private {
        vm.startPrank(_socketOwner);

        // deploy socket
        _a.socket__ = new Socket(_a.chainId);
        _b.socket__ = new Socket(_b.chainId);

        _a.notary__ = new Notary(_a.chainId);
        _b.notary__ = new Notary(_b.chainId);

        _a.socket__.setNotary(address(_a.notary__));
        _b.socket__.setNotary(address(_b.notary__));

        // deploy accumulators
        _a.accum__ = new SingleAccum(
            address(_a.socket__),
            address(_a.notary__)
        );
        _b.accum__ = new SingleAccum(
            address(_b.socket__),
            address(_b.notary__)
        );

        // deploy deaccumulators
        _a.deaccum__ = new SingleDeaccum();
        _b.deaccum__ = new SingleDeaccum();

        vm.stopPrank();
    }

    function _initSigner() private {
        // deduce signer address from private key
        _signer = vm.addr(_signerPrivateKey);

        vm.startPrank(_socketOwner);

        _a.notary__.grantRole(ATTESTER_ROLE, _signer);
        _b.notary__.grantRole(ATTESTER_ROLE, _signer);

        // grant signer role
        _a.notary__.grantSignerRole(_b.chainId, _signer);
        _b.notary__.grantSignerRole(_a.chainId, _signer);

        vm.stopPrank();
    }

    function _deployPlugContracts() private {
        vm.startPrank(_counterOwner);

        // deploy counters
        _a.counter__ = new Counter(address(_a.socket__));
        _b.counter__ = new Counter(address(_b.socket__));

        // deploy verifiers
        _a.verifier__ = new AcceptWithTimeout(
            0,
            address(_a.socket__),
            _counterOwner
        );
        _b.verifier__ = new AcceptWithTimeout(
            0,
            address(_b.socket__),
            _counterOwner
        );

        vm.stopPrank();
    }

    function _configPlugContracts(bool isSequential_) private {
        hoax(_counterOwner);
        _a.counter__.setSocketConfig(
            _b.chainId,
            address(_b.counter__),
            address(_a.accum__),
            address(_a.deaccum__),
            address(_a.verifier__),
            isSequential_
        );

        hoax(_counterOwner);
        _b.counter__.setSocketConfig(
            _a.chainId,
            address(_a.counter__),
            address(_b.accum__),
            address(_b.deaccum__),
            address(_b.verifier__),
            isSequential_
        );
    }

    function _initPausers() private {
        // add pausers
        hoax(_counterOwner);
        _a.verifier__.AddPauser(_pauser, _b.chainId);
        hoax(_counterOwner);
        _b.verifier__.AddPauser(_pauser, _a.chainId);

        // activate remote chains
        hoax(_pauser);
        _a.verifier__.Activate(_b.chainId);
        hoax(_pauser);
        _b.verifier__.Activate(_a.chainId);
    }

    function _getLatestSignature(ChainContext storage src_)
        private
        returns (
            bytes32 root,
            uint256 packetId,
            Signature memory sig
        )
    {
        (root, packetId) = src_.accum__.getNextPacket();
        bytes32 digest = keccak256(
            abi.encode(src_.chainId, address(src_.accum__), packetId, root)
        );
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(
            _signerPrivateKey,
            digest
        );
        sig = Signature(sigV, sigR, sigS);
    }

    function _submitSignatureOnSrc(
        ChainContext storage src_,
        Signature memory sig_
    ) private {
        hoax(_signer);
        src_.notary__.submitSignature(
            sig_.v,
            sig_.r,
            sig_.s,
            address(src_.accum__)
        );
    }

    function _submitRootOnDst(
        ChainContext storage src_,
        ChainContext storage dst_,
        Signature memory sig_,
        uint256 packetId_,
        bytes32 root_
    ) private {
        hoax(_raju);
        dst_.notary__.submitRemoteRoot(
            sig_.v,
            sig_.r,
            sig_.s,
            src_.chainId,
            address(src_.accum__),
            packetId_,
            root_
        );
    }

    function _executePayloadOnDst(
        ChainContext storage src_,
        ChainContext storage dst_,
        uint256 packetId_,
        uint256 nonce_,
        bytes memory payload_,
        bytes memory proof_
    ) private {
        hoax(_raju);
        dst_.socket__.execute(
            src_.chainId,
            address(dst_.counter__),
            nonce_,
            _signer,
            address(src_.accum__),
            packetId_,
            payload_,
            proof_
        );
    }
}
