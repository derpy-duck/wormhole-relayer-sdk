// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.13;

import {IWormhole} from "../../../src/interfaces/IWormhole.sol";
import "./BytesLib.sol";

import "forge-std/Vm.sol";
import "forge-std/console.sol";

/**
 * @title A Wormhole Guardian Simulator
 * @notice This contract simulates signing Wormhole messages emitted in a forge test.
 * It overrides the Wormhole guardian set to allow for signing messages with a single
 * private key on any EVM where Wormhole core contracts are deployed.
 * @dev This contract is meant to be used when testing against a mainnet fork.
 */
contract WormholeSimulator {
    using BytesLib for bytes;

    // Taken from forge-std/Script.sol
    address private constant VM_ADDRESS =
        address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));
    Vm public constant vm = Vm(VM_ADDRESS);

    // Allow access to Wormhole
    IWormhole public wormhole;

    // Save the guardian PK to sign messages with
    uint256 private devnetGuardianPK;

    /**
     * @param wormhole_ address of the Wormhole core contract for the mainnet chain being forked
     * @param devnetGuardian private key of the devnet Guardian
     */
    constructor(address wormhole_, uint256 devnetGuardian) {
        wormhole = IWormhole(wormhole_);
        devnetGuardianPK = devnetGuardian;
        overrideToDevnetGuardian(vm.addr(devnetGuardian));
    }

    function overrideToDevnetGuardian(address devnetGuardian) internal {
        {
            bytes32 data = vm.load(address(this), bytes32(uint256(2)));
            require(data == bytes32(0), "incorrect slot");

            // Get slot for Guardian Set at the current index
            uint32 guardianSetIndex = wormhole.getCurrentGuardianSetIndex();
            bytes32 guardianSetSlot = keccak256(
                abi.encode(guardianSetIndex, 2)
            );

            // Overwrite all but first guardian set to zero address. This isn't
            // necessary, but just in case we inadvertently access these slots
            // for any reason.
            uint256 numGuardians = uint256(
                vm.load(address(wormhole), guardianSetSlot)
            );
            for (uint256 i = 1; i < numGuardians; ) {
                vm.store(
                    address(wormhole),
                    bytes32(
                        uint256(keccak256(abi.encodePacked(guardianSetSlot))) +
                            i
                    ),
                    bytes32(0)
                );
                unchecked {
                    i += 1;
                }
            }

            // Now overwrite the first guardian key with the devnet key specified
            // in the function argument.
            vm.store(
                address(wormhole),
                bytes32(
                    uint256(keccak256(abi.encodePacked(guardianSetSlot))) + 0
                ), // just explicit w/ index 0
                bytes32(uint256(uint160(devnetGuardian)))
            );

            // Change the length to 1 guardian
            vm.store(
                address(wormhole),
                guardianSetSlot,
                bytes32(uint256(1)) // length == 1
            );

            // Confirm guardian set override
            address[] memory guardians = wormhole
                .getGuardianSet(guardianSetIndex)
                .keys;
            require(guardians.length == 1, "guardians.length != 1");
            require(
                guardians[0] == devnetGuardian,
                "incorrect guardian set override"
            );
        }
    }

    function doubleKeccak256(
        bytes memory body
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(body)));
    }

    function parseVMFromLogs(
        Vm.Log memory log
    ) internal pure returns (IWormhole.VM memory vm_) {
        uint256 index = 0;

        // emitterAddress
        vm_.emitterAddress = bytes32(log.topics[1]);

        // sequence
        vm_.sequence = log.data.toUint64(index + 32 - 8);
        index += 32;

        // nonce
        vm_.nonce = log.data.toUint32(index + 32 - 4);
        index += 32;

        // skip random bytes
        index += 32;

        // consistency level
        vm_.consistencyLevel = log.data.toUint8(index + 32 - 1);
        index += 32;

        // length of payload
        uint256 payloadLen = log.data.toUint256(index);
        index += 32;

        vm_.payload = log.data.slice(index, payloadLen);
        index += payloadLen;

        // trailing bytes (due to 32 byte slot overlap)
        index += log.data.length - index;

        require(index == log.data.length, "failed to parse wormhole message");
    }

    /**
     * @notice Finds published Wormhole events in forge logs
     * @param logs The forge Vm.log captured when recording events during test execution
     * @param numMessages The expected number of Wormhole events in the forge logs
     */
    function fetchWormholeMessageFromLog(
        Vm.Log[] memory logs,
        uint8 numMessages
    ) public pure returns (Vm.Log[] memory) {
        // create log array to save published messages
        Vm.Log[] memory published = new Vm.Log[](numMessages);

        uint8 publishedIndex = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] ==
                keccak256(
                    "LogMessagePublished(address,uint64,uint32,bytes,uint8)"
                )
            ) {
                published[publishedIndex] = logs[i];
                publishedIndex += 1;
            }
        }

        return published;
    }

    /**
     * @notice Encodes Wormhole message body into bytes
     * @param vm_ Wormhole VM struct
     * @return encodedObservation Wormhole message body encoded into bytes
     */
    function encodeObservation(
        IWormhole.VM memory vm_
    ) public pure returns (bytes memory encodedObservation) {
        encodedObservation = abi.encodePacked(
            vm_.timestamp,
            vm_.nonce,
            vm_.emitterChainId,
            vm_.emitterAddress,
            vm_.sequence,
            vm_.consistencyLevel,
            vm_.payload
        );
    }

    /**
     * @notice Formats and signs a simulated Wormhole message using the emitted log from calling `publishMessage`
     * @param log The forge Vm.log captured when recording events during test execution
     * @return signedMessage Formatted and signed Wormhole message
     */
    function fetchSignedMessageFromLogs(
        Vm.Log memory log,
        uint16 emitterChainId
    ) public view returns (bytes memory signedMessage) {
        // Create message instance
        IWormhole.VM memory vm_;

        // Parse wormhole message from ethereum logs
        vm_ = parseVMFromLogs(log);

        // Set empty body values before computing the hash
        vm_.version = uint8(1);
        vm_.timestamp = uint32(block.timestamp);
        vm_.emitterChainId = emitterChainId;

        return encodeAndSignMessage(vm_);
    }

    /**
     * @notice Formats and signs a simulated Wormhole batch VAA given an array of Wormhole log entries
     * @param logs The forge Vm.log entries captured when recording events during test execution
     * @param nonce The nonce of the messages to be accumulated into the batch VAA
     * @return signedMessage Formatted and signed Wormhole message
     */
    function fetchSignedBatchVAAFromLogs(
        Vm.Log[] memory logs,
        uint32 nonce,
        uint16 emitterChainId,
        address emitterAddress
    ) public view returns (bytes memory signedMessage) {
        uint8 numObservations = 0;
        IWormhole.VM[] memory vm_ = new IWormhole.VM[](logs.length);

        for (uint256 i = 0; i < logs.length; i++) {
            vm_[i] = parseVMFromLogs(logs[i]);
            vm_[i].timestamp = uint32(block.timestamp);
            vm_[i].emitterChainId = emitterChainId;
            vm_[i].emitterAddress = bytes32(uint256(uint160(emitterAddress)));
            if (vm_[i].nonce == nonce) {
                numObservations += 1;
            }
        }

        bytes memory packedObservations;
        bytes32[] memory hashes = new bytes32[](numObservations);

        uint8 counter = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (vm_[i].nonce == nonce) {
                bytes memory observation = abi.encodePacked(
                    vm_[i].timestamp,
                    vm_[i].nonce,
                    vm_[i].emitterChainId,
                    vm_[i].emitterAddress,
                    vm_[i].sequence,
                    vm_[i].consistencyLevel,
                    vm_[i].payload
                );
                hashes[counter] = doubleKeccak256(observation);
                packedObservations = abi.encodePacked(
                    packedObservations,
                    uint8(counter),
                    uint32(observation.length),
                    observation
                );
                counter++;
            }
        }

        bytes32 batchHash = doubleKeccak256(
            abi.encodePacked(uint8(2), keccak256(abi.encodePacked(hashes)))
        );

        IWormhole.Signature[] memory sigs = new IWormhole.Signature[](1);
        (sigs[0].v, sigs[0].r, sigs[0].s) = vm.sign(
            devnetGuardianPK,
            batchHash
        );

        sigs[0].guardianIndex = 0;

        signedMessage = abi.encodePacked(
            uint8(2),
            wormhole.getCurrentGuardianSetIndex(),
            uint8(1),
            sigs[0].guardianIndex,
            sigs[0].r,
            sigs[0].s,
            uint8(sigs[0].v - 27),
            numObservations,
            hashes,
            numObservations,
            packedObservations
        );
    }

    /**
     * @notice Signs and preformatted simulated Wormhole message
     * @param vm_ The preformatted Wormhole message
     * @return signedMessage Formatted and signed Wormhole message
     */
    function encodeAndSignMessage(
        IWormhole.VM memory vm_
    ) public view returns (bytes memory signedMessage) {
        // Compute the hash of the body
        bytes memory body = encodeObservation(vm_);
        vm_.hash = doubleKeccak256(body);

        // Sign the hash with the devnet guardian private key
        IWormhole.Signature[] memory sigs = new IWormhole.Signature[](1);
        (sigs[0].v, sigs[0].r, sigs[0].s) = vm.sign(devnetGuardianPK, vm_.hash);
        sigs[0].guardianIndex = 0;

        signedMessage = abi.encodePacked(
            vm_.version,
            wormhole.getCurrentGuardianSetIndex(),
            uint8(sigs.length),
            sigs[0].guardianIndex,
            sigs[0].r,
            sigs[0].s,
            sigs[0].v - 27,
            body
        );
    }

    /**
     * @notice Sets the wormhole protocol fee
     * @param newFee The new wormhole fee
     */
    function setMessageFee(uint256 newFee) public {
        bytes32 coreModule = 0x00000000000000000000000000000000000000000000000000000000436f7265;
        bytes memory message = abi.encodePacked(
            coreModule,
            uint8(3),
            uint16(wormhole.chainId()),
            newFee
        );
        IWormhole.VM memory preSignedMessage = IWormhole.VM({
            version: 1,
            timestamp: uint32(block.timestamp),
            nonce: 0,
            emitterChainId: wormhole.governanceChainId(),
            emitterAddress: wormhole.governanceContract(),
            sequence: 0,
            consistencyLevel: 200,
            payload: message,
            guardianSetIndex: 0,
            signatures: new IWormhole.Signature[](0),
            hash: bytes32("")
        });

        bytes memory signed = encodeAndSignMessage(preSignedMessage);
        wormhole.submitSetMessageFee(signed);
    }
}
