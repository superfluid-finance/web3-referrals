// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import { ISuperfluid, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import "./Web3Referrals.sol";
// import oz Ownable
import "@openzeppelin/contracts/access/Ownable.sol";

contract Web3ReferralsFactory is Ownable{
    ISuperfluid public host;
    // This protocol params only affect instances deployed in the future
    // Protocol fee recipient
    address public protocolFeeRecipient;
    // Protocol fee per million
    uint32 public protocolFeePm;

    event InstanceDeployed(address indexed instance);

    constructor(ISuperfluid host_, address protocolFeeRecipient_, uint32 protocolFeePm_) {
        host = host_;
        protocolFeeRecipient = protocolFeeRecipient_;
        protocolFeePm = protocolFeePm_;
    }

    function deployInstance(ISuperToken superToken_, address merchant_, uint32[] memory referralFeeTable_)
        public returns (Web3Referrals instance)
    {
        instance = new Web3Referrals(
            host, superToken_, merchant_, referralFeeTable_,  protocolFeeRecipient, protocolFeePm
        );
        emit InstanceDeployed(address(instance));
    }
}