// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import { ISuperfluid, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperAppBaseFlow } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBaseFlow.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

using SuperTokenV1Library for ISuperToken;

/*
* TODO: SuperAppBaseFlow assumes we'll use a EOA deployer. We'll not!
*/
contract Web3Referrals is SuperAppBaseFlow {
    error NOT_ACCEPTED_SUPERTOKEN();
    error INVALID_REFERRAL_FEE_TABLE();

    // Max number of levels the referral is allowed to have
    // Needs to be set such that the block gas limit cannot be exceeded
    uint8 constant MAX_LEVELS = 10;

    ISuperfluid public host;
    uint32[] public referralFeeTable; // flowrate scaling factors per million
    address public merchant; // receiver of the flows after subtracting referrer flows
    // linked list which can store referral relationships of arbitrary depth
    mapping (address referree => address referrer) public referrals;
    ISuperToken public acceptedSuperToken; // assumption: only 1 SuperToken accepted

    constructor(ISuperfluid host_, ISuperToken superToken_, address merchant_, uint32[] memory referralFeeTable_)
        SuperAppBaseFlow(host_, true, true, true, "")
    {
        host = host_;
        acceptedSuperToken = superToken_;
        merchant = merchant_;
        if (!isReferralFeeTableValid(referralFeeTable_)) {
            revert INVALID_REFERRAL_FEE_TABLE();
        }
        referralFeeTable = referralFeeTable_;
    }

    function isAcceptedSuperToken(ISuperToken superToken) public view override returns (bool) {
        return superToken == acceptedSuperToken;
    }

    function onFlowCreated(
        ISuperToken superToken,
        address sender,
        bytes calldata ctx
    ) internal override returns (bytes memory newCtx) {
        if (!isAcceptedSuperToken(superToken)) revert NOT_ACCEPTED_SUPERTOKEN();
        newCtx = ctx;

        bytes memory userData = host.decodeCtx(ctx).userData;
        if (userData.length != 0) {
            // get and persist referrer
            address referrer = abi.decode(userData, (address));
            referrals[sender] = referrer;
            // TODO: what if there's already a referrer set?´
        }

        int96 inFlowRate = superToken.getFlowRate(sender, address(this));
        int96 referrersOutflowRate;
        (referrersOutflowRate, newCtx) = adjustReferrersFlows(sender, 0, inFlowRate, newCtx);

        int96 merchantFlowRate = inFlowRate - referrersOutflowRate;
        newCtx = createOrUpdateFlow(merchant, merchantFlowRate, newCtx);
    }

    // TODO
    //function onFlowUpdated
    //function onFlowDeleted

    // Internal functions

    function isReferralFeeTableValid(uint32[] memory table) internal pure returns (bool) {
        // get length
        uint256 levels = uint256(table.length);
        if (levels > MAX_LEVELS) {
            return false;
        }
        uint32 sumPPM = 0;
        for (uint256 i = 0; i < levels; i++) {
            sumPPM += table[i];
        }
        // the sum of the referral fees can't be more than 100%
        return sumPPM <= 1e6;
    }

    /// get the flowrate scaled by a given factor (per million)
    function getScaledFlowrate(int96 flowRate, uint32 scalingFactorPM) internal pure returns (int96 scaledFlowRate){
        scaledFlowRate = flowRate * int96(uint96(scalingFactorPM)) / 1e6;
    }

    /*
    * Adjusts all the flows according to the referral fee.
    * The remainder goes to the merchant
    */
    function adjustReferrersFlows(address referree, uint8 level, int96 inFlowRate, bytes memory ctx) internal 
        returns (int96 addedOutFlowRate, bytes memory newCtx) 
    {
        newCtx = ctx;

        address referrer = referrals[referree];

        // If no referrer or level exceeds the referral fee table length, return
        if (referrer == address(0) || level >= referralFeeTable.length) {
            return (0, newCtx);
        }

        int96 referrerFlowRate = getScaledFlowrate(inFlowRate, referralFeeTable[level]);
        if (referrerFlowRate > 0) { // may be 0 due to rounding if numbers get very small
            newCtx = createOrUpdateFlow(referrer, referrerFlowRate, newCtx);
            (addedOutFlowRate, newCtx) = adjustReferrersFlows(referrer, level + 1, inFlowRate, newCtx);
            addedOutFlowRate += referrerFlowRate;
        }
    }

    function createOrUpdateFlow(address receiver, int96 deltaFlowRate, bytes memory ctx) internal returns (bytes memory newCtx) {
        int96 currentFlowRate = acceptedSuperToken.getFlowRate(address(this), receiver);
        if (currentFlowRate == 0) {
            newCtx = acceptedSuperToken.createFlowWithCtx(receiver, deltaFlowRate, ctx);
        } else {
            newCtx = acceptedSuperToken.updateFlowWithCtx(receiver, currentFlowRate + deltaFlowRate, ctx);
        }
    }
}