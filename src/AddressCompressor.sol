// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

// Whenever any character in this file changes, the deterministic address will change!
// For that reason, nothing is imported.
contract AddressCompressor {
    event CAddrCreated(address addr, bytes4 cAddr);

    mapping (bytes4 cAddr => address addr) public cAddrToAddressMap;
    mapping (address addr => bytes4 cAddr) public addressToCAddrMap;
    bytes4 public nextCAddr = bytes4(uint32(1));

    function getCAddr(address address_) public view returns(bytes4) {
        return addressToCAddrMap[address_];
    }

    function getOrCreateCAddr(address address_) public returns(bytes4) {
        return getCAddr(address_) != 0 ? getCAddr(address_) : _createCAddr(address_);
    }

    function getAddress(bytes4 cAddr) public view returns(address) {
        return cAddrToAddressMap[cAddr];
    }

    // ======= internal interface =======

    function _createCAddr(address address_) internal returns(bytes4 cAddr) {
        cAddr = nextCAddr;
        cAddrToAddressMap[cAddr] = address_;
        addressToCAddrMap[address_] = cAddr;
        emit CAddrCreated(address_, cAddr);
        // If the cAddr space is exhausted, this will revert.
        nextCAddr = bytes4(uint32(cAddr) + 1);
    }
}

