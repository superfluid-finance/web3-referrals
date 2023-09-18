// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Web3Referrals.sol";

import { ERC1820RegistryCompiled } from "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import {
    SuperfluidFrameworkDeployer,
    ISuperTokenFactory,
    ERC20WithTokenInfo
} from "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeployer.sol";
import {
    ISuperfluid,
    ISuperToken
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { CFAv1Forwarder } from "@superfluid-finance/ethereum-contracts/contracts/utils/CFAv1Forwarder.sol";

using SuperTokenV1Library for ISuperToken;

contract Web3ReferralsTest is Test {
    Web3Referrals public w3r;
    SuperfluidFrameworkDeployer.Framework internal sf;
    ISuperToken internal superToken;

    address alice = address(0x42);
    address bob = address(0x43);
    address dan = address(0x44);
    address merchant = address(0x69);

    uint32[] emptyReferralFeeTable = new uint32[](0);
    uint32[] oneLevelReferralFeeTable = [uint32(100000), uint32(20000)]; // 10% for first level
    uint32[] twoLevelReferralFeeTable = [uint32(80000), uint32(20000)]; // 8% for first level, 2% for second level

    function setUp() public {
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        SuperfluidFrameworkDeployer deployer = new SuperfluidFrameworkDeployer();
        deployer.deployTestFramework();
        sf = deployer.getFramework();

        superToken = deployer.deployPureSuperToken("TestToken", "TST", 10e32);
        superToken.transfer(alice, 1e32);
        superToken.transfer(bob, 1e32);
        superToken.transfer(dan, 1e32);
    }

    // For flowrate fuzzing, uint64 is a good input type

    function testFuzzWithZeroLevels(uint64 inFlowRate) public {
        vm.assume(inFlowRate > 0);
        w3r = new Web3Referrals(sf.host, superToken, merchant, emptyReferralFeeTable);
        vm.startPrank(alice);
        // without referral address encoded in userData
        superToken.createFlow(address(w3r), toI96(inFlowRate));
        assertEq(toU256(inFlowRate), toU256(superToken.getFlowRate(address(w3r), merchant)));

        vm.startPrank(bob);
        // with referral address encoded in userData
        superToken.createFlow(address(w3r), toI96(inFlowRate), abi.encode(bob));
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

    function testWithTwoLevel() public {
        w3r = new Web3Referrals(sf.host, superToken, merchant, twoLevelReferralFeeTable);
        assertEq(twoLevelReferralFeeTable.length, 2, "wrong table size");
        vm.startPrank(bob);
        // bob was brought by dan
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(dan));
        vm.startPrank(alice);
        // alice was brought by bob
        superToken.createFlow(address(w3r), toI96(100e18), abi.encode(bob));

        // bob shall get 8% of one stream
        assertEq(8e18, toU256(superToken.getFlowRate(address(w3r), bob)), "wrong flowrate to bob");
        // dan shall get 2% of the first stream (indirect referral) and 8% of the second stream (direct referral);
        assertEq(2e18 + 8e18, toU256(superToken.getFlowRate(address(w3r), dan)), "wrong flowrate to dan");
        // merchant shall get 92% of the first stream and 90% of the second stream
        assertEq(92e18 + 90e18, toU256(superToken.getFlowRate(address(w3r), merchant)), "wrong flowrate to merchant");
    }

    function testFuzzWithOneLevel(uint64 inFlowRate) public {
        vm.assume(inFlowRate > 0);
        w3r = new Web3Referrals(sf.host, superToken, merchant, oneLevelReferralFeeTable);
        vm.startPrank(alice);
        superToken.createFlow(address(w3r), toI96(inFlowRate), abi.encode(bob));
        // TODO check the flows
    }

    function testWithSuperTokenWithMinDeposit() public {
        // TODO
    }

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