import { Contract, Wallet } from "ethers";
import { deployContractWithArgs, storeAddresses, getInstance } from "../utils";

import { sealGasLimit } from "../../constants/config";
import {
  CORE_CONTRACTS,
  ChainSocketAddresses,
  DeploymentMode,
  networkToChainSlug,
} from "../../../src";
import deploySwitchboards from "./deploySwitchboard";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { socketOwner } from "../config";

let verificationDetails: any[] = [];
let allDeployed = false;

/**
 * Deploys network-independent socket contracts
 */
export const deploySocket = async (
  socketSigner: SignerWithAddress | Wallet,
  chainSlug: number,
  currentMode: DeploymentMode,
  deployedAddresses: ChainSocketAddresses
): Promise<any> => {
  const deployUtils = {
    addresses: deployedAddresses,
    mode: currentMode,
    signer: socketSigner,
    currentChainSlug: chainSlug,
  };

  try {
    const signatureVerifier: Contract = await getOrDeploy(
      CORE_CONTRACTS.SignatureVerifier,
      "contracts/utils/SignatureVerifier.sol",
      [],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.SignatureVerifier] =
      signatureVerifier.address;

    const hasher: Contract = await getOrDeploy(
      CORE_CONTRACTS.Hasher,
      "contracts/utils/Hasher.sol",
      [],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.Hasher] = hasher.address;

    const capacitorFactory: Contract = await getOrDeploy(
      CORE_CONTRACTS.CapacitorFactory,
      "contracts/CapacitorFactory.sol",
      [socketOwner],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.CapacitorFactory] =
      capacitorFactory.address;

    const gasPriceOracle: Contract = await getOrDeploy(
      CORE_CONTRACTS.GasPriceOracle,
      "contracts/GasPriceOracle.sol",
      [socketOwner, chainSlug],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.GasPriceOracle] =
      gasPriceOracle.address;

    const executionManager: Contract = await getOrDeploy(
      CORE_CONTRACTS.ExecutionManager,
      "contracts/ExecutionManager.sol",
      [gasPriceOracle.address, socketOwner],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.ExecutionManager] =
      executionManager.address;

    const transmitManager: Contract = await getOrDeploy(
      CORE_CONTRACTS.TransmitManager,
      "contracts/TransmitManager.sol",
      [
        signatureVerifier.address,
        gasPriceOracle.address,
        socketOwner,
        chainSlug,
        sealGasLimit[networkToChainSlug[chainSlug]],
      ],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.TransmitManager] =
      transmitManager.address;

    const socket: Contract = await getOrDeploy(
      CORE_CONTRACTS.Socket,
      "contracts/socket/Socket.sol",
      [
        chainSlug,
        hasher.address,
        transmitManager.address,
        executionManager.address,
        capacitorFactory.address,
        socketOwner,
      ],
      deployUtils
    );
    deployUtils.addresses[CORE_CONTRACTS.Socket] = socket.address;

    // switchboards deploy
    const result = await deploySwitchboards(
      networkToChainSlug[chainSlug],
      socketSigner,
      deployedAddresses,
      verificationDetails,
      currentMode
    );

    deployUtils.addresses = result["sourceConfig"];

    verificationDetails = result["verificationDetails"];

    const socketBatcher: Contract = await getOrDeploy(
      "SocketBatcher",
      "contracts/socket/SocketBatcher.sol",
      [socketOwner],
      deployUtils
    );
    deployUtils.addresses["SocketBatcher"] = socketBatcher.address;

    // plug deployments
    const counter: Contract = await getOrDeploy(
      "Counter",
      "contracts/examples/Counter.sol",
      [socket.address],
      deployUtils
    );
    deployUtils.addresses["Counter"] = counter.address;

    allDeployed = true;
    console.log(deployUtils.addresses);
    console.log("Contracts deployed!");
  } catch (error) {
    console.log("Error in deploying setup contracts", error);
  }

  await storeAddresses(
    deployUtils.addresses,
    deployUtils.currentChainSlug,
    deployUtils.mode
  );
  return {
    verificationDetails,
    allDeployed,
    deployedAddresses: deployUtils.addresses,
  };
};

async function getOrDeploy(
  contractName: string,
  path: string,
  args: any[],
  deployUtils
): Promise<Contract> {
  let contract: Contract;
  if (!deployUtils.addresses[contractName]) {
    contract = await deployContractWithArgs(
      contractName,
      args,
      deployUtils.signer
    );
    verificationDetails.push([contract.address, contractName, path, args]);
    console.log(
      `${contractName} deployed on ${deployUtils.currentChainSlug} for ${deployUtils.mode} at address ${contract.address}`
    );
  } else {
    contract = await getInstance(
      contractName,
      deployUtils.addresses[contractName]
    );
    console.log(
      `${contractName} found on ${deployUtils.currentChainSlug} for ${deployUtils.mode} at address ${contract.address}`
    );
  }

  return contract;
}
