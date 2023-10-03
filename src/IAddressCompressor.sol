// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;


/**
* Simple mechanism for mapping addresses to compressed addresses (cAddr) of 4 bytes.
* The cAddrs are assigned sequentially, starting from 0x00000001.
* While only a small fraction of all possible addresses can by mapped, it's still a namsepace of 2^32,
* which is the same as the number of IPv4 addresses.
*/
interface IAddressCompressor {
    // emitted when a new mapping between an address and a cAddr is created
    event CAddrCreated(address addr, bytes4 cAddr);

    // Returns the cAddr assigned to the address or 0 if the address is not mapped.
    function getCAddr(address address_) external view returns(bytes4);

    // Returns the address of a previously assigned cAddr or 0 if none was assigned to that address.
    function getAddress(bytes4 cAddr) external view returns(address);

    // Creates a new mapping if it doesn't exist yet and returns the cAddr.
    function getOrCreateCAddr(address address_) external returns(bytes4);
}

// Convenience helper to get the deterministic address at which the contract is deployed.
library AddressCompressorLib {
    function getDeployedAt() internal pure returns(address) {
        return 0xC57D3E91b52AC3D85437cF5Dd4CAe8Fc65922D20;
    }

    function formatAsAddress(bytes4 cAddr) internal pure returns(address) {
        return address(uint160(uint32(cAddr)));
    }

    function toString(bytes4 cAddr) internal pure returns(string memory) {
        bytes memory bytesRepresentation = abi.encodePacked(cAddr);
        return string(bytesRepresentation);
    }
}