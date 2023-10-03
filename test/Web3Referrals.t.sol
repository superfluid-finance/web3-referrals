// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Web3Referrals.sol";
import "../src/AddressCompressor.sol";
import { AddressCompressorLib } from "../src/IAddressCompressor.sol";

import { ERC1820RegistryCompiled } from "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { SuperfluidFrameworkDeployer } from "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeployer.sol";
import { ISuperfluidGovernance, ISuperfluidToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperfluidGovernanceBase } from "@superfluid-finance/ethereum-contracts/contracts/gov/SuperfluidGovernanceBase.sol";

using SuperTokenV1Library for ISuperToken;

contract Web3ReferralsTest is Test {
    Web3Referrals public w3r;
    SuperfluidFrameworkDeployer.Framework internal sf;
    ISuperToken internal superToken;
    AddressCompressor addressCompressor;

    address alice = address(0x42);
    address bob = address(0x43);
    address dan = address(0x44);
    address kaspar = address(0x45);
    address merchant = address(0x69);

    // special referrers
    address walletX = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
    address platformX = address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC);

    uint32[] emptyReferralFeeTable = new uint32[](0);
    uint32[] oneLevelReferralFeeTable = [uint32(100000), uint32(20000)]; // 10% for first level
    uint32[] twoLevelReferralFeeTable = [uint32(80000), uint32(20000)]; // 8% for first level, 2% for second level

    // =========== SETUP =============

    function setUp() public {
        // deploy prerequisites for SF framework
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        // deploy SF framework
        SuperfluidFrameworkDeployer deployer = new SuperfluidFrameworkDeployer();
        deployer.deployTestFramework();
        sf = deployer.getFramework();

        // deploy SuperToken and distribute to accounts
        superToken = deployer.deployPureSuperToken("TestToken", "TST", 10e32);
        superToken.transfer(alice, 1e32);
        superToken.transfer(bob, 1e32);
        superToken.transfer(dan, 1e32);
        superToken.transfer(kaspar, 1e32);

        // deploy AddressCompressor, expected to exist at its deterministic address by Web3Referrals contract
        addressCompressor = _deployAddressCompressorWithCreate2Proxy();

        // see https://github.com/superfluid-finance/protocol-monorepo/issues/1697
        superToken.increaseFlowRateAllowance(merchant, 1);
    }

    // deterministically deploys the AddressCompressor contract using CREATE2.
    // Uses https://github.com/Arachnid/deterministic-deployment-proxy, available on any chain, also in foundry devnets.
    // Note that the address will change with compiler or compiler settings (optimization, etc.) changes.
    function _deployAddressCompressorWithCreate2Proxy() internal returns (AddressCompressor) {
        address CREATE2_PROXY_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

        // Deploying through the create2 proxy allows us to yield the same address regardless of who makes the tx
        bytes memory ADDRESS_COMPRESSOR_CREATIONCODE = type(AddressCompressor).creationCode;
        // Changing the salt will change the address it's deployed to!
        bytes32 salt = keccak256(abi.encodePacked("AddressCompressor"));
        // The only way to know the address the contract will be deployed to by the proxy is to compute it.
        address computedAddr = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), CREATE2_PROXY_DEPLOYER, salt, keccak256(ADDRESS_COMPRESSOR_CREATIONCODE))))));
        // the tx is the same as a normal contract creation tx, with 2 differences:
        // * "to" shall be the proxy address instead of zero
        // * "data": prepend the salt (packed) to the initcode of the contract to be deployed
        (bool success,) = CREATE2_PROXY_DEPLOYER.call(abi.encodePacked(salt, ADDRESS_COMPRESSOR_CREATIONCODE));
        assertTrue(success);
        return AddressCompressor(computedAddr);
    }

    // =========== TESTS =============

    // For flowrate fuzzing, uint64 is a good input type

    function testAddressCompressorIsAtExpectedAddress() public {
        // make sure there's code at the expected address
        assertGe(address(addressCompressor).code.length, 1, "no code at expected address for AddressCompressor");
        // make sure the address matches the one hardcoded in the related lib
        assertEq(address(addressCompressor), AddressCompressorLib.getDeployedAt(), "AddressCompressor not at expected address");
    }

    // smoke test the compressor. TODO: move to its own repo
    function testAddressCompressor() public {
        address someAddr = address(0x777);
        bytes4 someCAddr = addressCompressor.getOrCreateCAddr(someAddr);
        console.log("got cAddr:");
        console.logBytes4(someCAddr);
        assertEq(addressCompressor.getAddress(someCAddr), someAddr, "reverse lookup failed");

        bytes4 someCAddrRetry = addressCompressor.getOrCreateCAddr(someAddr);
        assertEq(someCAddrRetry, someCAddr, "doesn't return pre-existing cAddr");
    }

    function testFuzzWithZeroLevels(uint64 inFlowRate) public {
        vm.assume(inFlowRate > 0);
        w3r = new Web3Referrals(sf.host, superToken, merchant, emptyReferralFeeTable);
        vm.startPrank(alice);
        // without referral address encoded in userData
        superToken.createFlow(address(w3r), toI96(inFlowRate));
        assertEq(toU256(inFlowRate), toU256(superToken.getFlowRate(address(w3r), merchant)));

        vm.startPrank(bob);
        // with referral address encoded in userData
        superToken.createFlow(address(w3r), toI96(inFlowRate), abi.encode(alice));
        assertEq(toU256(inFlowRate) * 2, toU256(superToken.getFlowRate(address(w3r), merchant)));
    }

     function testWithZeroLevels() public {
        int96 inFlowRate = 1e12;
        w3r = new Web3Referrals(sf.host, superToken, merchant, emptyReferralFeeTable);
        vm.startPrank(alice);
        uint256 gasBefore = gasleft();
        // without referral address encoded in userData
        superToken.createFlow(address(w3r), inFlowRate);
        console.log("0 levels | gas consumed by alice:", gasBefore - gasleft());
        assertEq(toU256(inFlowRate), toU256(superToken.getFlowRate(address(w3r), merchant)));

        vm.startPrank(bob);
        gasBefore = gasleft();
        // with referral address encoded in userData
        superToken.createFlow(address(w3r), inFlowRate, abi.encode(alice));
        console.log("0 levels | gas consumed by bob:", gasBefore - gasleft());
        assertEq(toU256(inFlowRate) * 2, toU256(superToken.getFlowRate(address(w3r), merchant)));
    }

    function testWithOneLevel() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        vm.startPrank(alice);
        // bob recommends alice
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(bob));

        // referrer shall get 10%
        assertEq(10e18, toU256(superToken.getFlowRate(address(w3r), bob)));
        // merchant shall get 90%
        assertEq(90e18, toU256(superToken.getFlowRate(address(w3r), merchant)));
    }

    function testReferTwice(uint64 inFlowRate1, uint64 inFlowRate2) public {
        vm.assume(inFlowRate1 > 0);
        vm.assume(inFlowRate2 > 0);
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        vm.startPrank(alice);
        // bob recommends alice
        superToken.createFlow(address(w3r), toI96(inFlowRate1), abi.encode(bob));
        vm.startPrank(dan);
        // bob also recommends dan
        superToken.createFlow(address(w3r), toI96(inFlowRate2), abi.encode(bob));

        // using >= assertions because of rounding artifacts

        // bob shall get 10% of both
        assertGe(
            toU256(superToken.getFlowRate(address(w3r), bob)),
            toU256(inFlowRate1) * 10 / 100 + toU256(inFlowRate2) * 10 / 100,
            "wrong flowrate to bob"
        );
        // merchant shall get 90% of both
        assertGe(
            toU256(superToken.getFlowRate(address(w3r), merchant)),
            toU256(inFlowRate1) * 90 / 100 + toU256(inFlowRate2) * 90 / 100,
            "wrong flowrate to merchant"
        );
    }

    function testWithTwoLevels() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, twoLevelReferralFeeTable);
        assertEq(twoLevelReferralFeeTable.length, 2, "wrong table size");

        vm.startPrank(bob);
        uint256 gasBefore = gasleft();
        // bob was brought by dan
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(dan));
        console.log("2 levels | gas consumed by bob:", gasBefore - gasleft());

        vm.startPrank(alice);
        gasBefore = gasleft();
        // alice was brought by bob
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(bob));
        console.log("2 levels | gas consumed by alice:", gasBefore - gasleft());

        // bob shall get 8% of one stream
        assertEq(8e18, toU256(superToken.getFlowRate(address(w3r), bob)), "wrong flowrate to bob");
        // dan shall get 2% of the first stream (indirect referral) and 8% of the second stream (direct referral);
        assertEq(2e18 + 8e18, toU256(superToken.getFlowRate(address(w3r), dan)), "wrong flowrate to dan");
        // merchant shall get 92% of the first stream and 90% of the second stream
        assertEq(92e18 + 90e18, toU256(superToken.getFlowRate(address(w3r), merchant)), "wrong flowrate to merchant");

        // one more stream, triggering only 1 flow creation, for measuring gas costs
        vm.startPrank(kaspar);
        gasBefore = gasleft();
        // kaspar was brought by bob. So this triggers an update of 3 flows (to merchant, bob, dan) plus creation of 1 new one (from kaspar)
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(bob));
        console.log("2 levels | gas consumed by kaspar:", gasBefore - gasleft());
        assertEq(92e18 + 90e18 + 90e18, toU256(superToken.getFlowRate(address(w3r), merchant)), "wrong flowrate to merchant");
    }

    function testFuzzWithOneLevels(uint64 inFlowRate) public {
        vm.assume(inFlowRate > 0);
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        vm.startPrank(alice);
        superToken.createFlow(address(w3r), toI96(inFlowRate), abi.encode(bob));

        // bob shall get 10%
        assertGe(
            toU256(superToken.getFlowRate(address(w3r), bob)),
            toU256(inFlowRate) * 10 / 100,
            "wrong flowrate to bob"
        );
        // merchant shall get 90%
        assertGe(
            toU256(superToken.getFlowRate(address(w3r), merchant)),
            toU256(inFlowRate) * 90 / 100,
            "wrong flowrate to merchant"
        );
    }

    function testCantReferToSelf() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        vm.startPrank(alice);
        //superToken.createFlow(address(w3r), toI96(100e18), abi.encode(alice));
        superToken.createFlow(address(w3r), toI96(100e18), 
            abi.encode(alice));
        // referral ignored, full flowrate going to the merchant
        assertEq(100e18, toU256(superToken.getFlowRate(address(w3r), merchant)));
    }

    function testStreamWithOneSpecialReferrer() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        // set up walletX as special referrer
        uint32 walletXSharePm = 10000; // 1%
        uint8 rType = 1; // we pretend 1 to mean wallets
        // TODO: verify emitted event
        bytes4 walletXCAddr = w3r.setSpecialReferrer(walletX, walletXSharePm, rType);

        vm.startPrank(alice);
        // alice is referred by bob and by special referrer walletX
        bytes memory userData = abi.encodePacked(bytes4(0), bytes4(0), walletXCAddr, bob);
        superToken.createFlow(address(w3r), toI96(100e18), userData);

        assertEq(1e18, toU256(superToken.getFlowRate(address(w3r), walletX)), "wrong flowrate to walletX (special referrer)");
        assertEq(10e18, toU256(superToken.getFlowRate(address(w3r), bob)), "wrong flowrate to bob");
        assertEq(89e18, toU256(superToken.getFlowRate(address(w3r), merchant)), "wrong flowrate to merchant");
    }

    function testStreamWithTwoSpecialReferrers() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        // set up walletX as first special referrer
        uint32 walletXSharePm = 10000; // 1%
        uint8 walletXRType = 1; // we pretend 1 to mean wallets
        bytes4 walletXCAddr = w3r.setSpecialReferrer(walletX, walletXSharePm, walletXRType);

        // set up platformX as second special referrer
        uint32 platformXSharePm = 30000; // 3%
        uint8 platformXRType = 2; // we pretend 2 to mean platforms
        bytes4 platformXCAddr = w3r.setSpecialReferrer(platformX, platformXSharePm, platformXRType);

        vm.startPrank(alice);
        // alice is referred by bob and by special referrers walletX and platformX
        bytes memory userData = abi.encodePacked(bytes4(0), platformXCAddr, walletXCAddr, bob);
        superToken.createFlow(address(w3r), toI96(100e18), userData);

        assertEq(1e18, toU256(superToken.getFlowRate(address(w3r), walletX)), "wrong flowrate to walletX (special referrer)");
        assertEq(3e18, toU256(superToken.getFlowRate(address(w3r), platformX)), "wrong flowrate to platformX (special referrer)");
        assertEq(10e18, toU256(superToken.getFlowRate(address(w3r), bob)), "wrong flowrate to bob");
        // TODO: this is slightly off due to deposit clipping. To be figured out
        assertEq(86e18, toU256(superToken.getFlowRate(address(w3r), merchant)), "wrong flowrate to merchant");
    }

    function testHandleIncreasedMinDeposit() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        vm.startPrank(alice);
        // bob recommends alice
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(bob));

        // referrer shall get 10%
        assertEq(10e18, toU256(superToken.getFlowRate(address(w3r), bob)));
        // merchant shall get 90%
        assertEq(90e18, toU256(superToken.getFlowRate(address(w3r), merchant)));

        // increase min deposit
        ISuperfluidGovernance gov = sf.host.getGovernance();
        (SuperfluidGovernanceBase(address(gov))).setSuperTokenMinimumDeposit(sf.host, ISuperfluidToken(address(0)), 10e18);
    }

    // TODO: additionally implement:

    /*
    function testWithSuperTokenWithMinDeposit() public {}

    function testUpdateInStream() public {}

    function testCloseInStream() public {}

    // Test case with changing min deposit:
    // Alice creates subscription, sets dan as referrer
    // Bob also subscribes with dan as referrer
    // min deposit is dramatically increased
    // Alice closes the stream, triggering an update of the flow to dan
    // Question: can this cause the tx to be blocked because there's not enough app credit?

    */

    // Helpers

    function toU256(uint64 u64) internal pure returns (uint256) {
        return uint256(u64);
    }

    function toU256(int96 i96) internal pure returns (uint256) {
        return uint256(uint96(i96));
    }

    function toI96(uint256 u256) internal pure returns (int96) {
        return int96(uint96(u256));
    }
}