// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import { ISuperfluid, ISuperToken, IConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperAppBaseFlow } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBaseFlow.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAddressCompressor, AddressCompressorLib } from "./IAddressCompressor.sol";
import "forge-std/console.sol";

using SuperTokenV1Library for ISuperToken;

/*
* TODO: SuperAppBaseFlow assumes we'll use a EOA deployer. We'll not!
*/
contract Web3Referrals is SuperAppBaseFlow, Ownable {
    error NOT_ACCEPTED_SUPERTOKEN();
    error INVALID_REFERRAL_FEE_TABLE();

    // Max number of levels the referral is allowed to have
    // Needs to be set such that the block gas limit cannot be exceeded
    uint8 constant MAX_LEVELS = 10;

    // Protocol fee per million
    uint32 immutable PROTOCOL_FEE_PM;
    // TODO: what shall we put here?
    address immutable PROTOCOL_FEE_RECIPIENT;

    ISuperfluid public host;
    IConstantFlowAgreementV1 _cfa;
    uint32[] public referralFeeTable; // flowrate scaling factors per million
    address public merchant; // receiver of the flows after subtracting referrer flows
    // linked list which can store referral relationships of arbitrary depth
    mapping (address referree => address referrer) public referrals;
    ISuperToken public acceptedSuperToken; // assumption: only 1 SuperToken accepted
    IAddressCompressor public addressCompressor = IAddressCompressor(AddressCompressorLib.getDeployedAt());

    constructor(
        ISuperfluid host_, ISuperToken superToken_, address merchant_, uint32[] memory referralFeeTable_, 
        address protocolFeeRecipient_, uint32 protocolFeePm_
    )
        SuperAppBaseFlow(host_, true, true, true, "")
    {
        host = host_;
        _cfa = IConstantFlowAgreementV1(address(host.getAgreementClass(
            keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1")
        )));
        acceptedSuperToken = superToken_;
        merchant = merchant_;
        if (!isReferralFeeTableValid(referralFeeTable_)) {
            revert INVALID_REFERRAL_FEE_TABLE();
        }
        referralFeeTable = referralFeeTable_;
        PROTOCOL_FEE_RECIPIENT = protocolFeeRecipient_;
        PROTOCOL_FEE_PM = protocolFeePm_;
    }

    function isAcceptedSuperToken(ISuperToken superToken) public view override returns (bool) {
        return superToken == acceptedSuperToken;
    }

    // data structure expected in userData. All fields are optional.
    struct UserDataStruct {
        address referrer; // the organic referrer
        bytes4 specialReferrer1; // first special referrer
        bytes4 specialReferrer2; // second special referrer
        bytes4 _reserved;
    }

    function _decodeUserData(bytes memory userData) internal pure returns (UserDataStruct memory) {
        address referrer = address(uint160(uint256(bytes32(userData))));
        // bytes4 takes the most significant bits, thus we need to shift left
        bytes4 specialReferrer1 = bytes4(bytes32(userData) << 64);
        bytes4 specialReferrer2 = bytes4(bytes32(userData) << 32);
        return UserDataStruct(referrer, specialReferrer1, specialReferrer2, bytes4(0));
    }

    function printAppCredit(bytes memory ctx) internal view {
        ISuperfluid.Context memory sfContext = host.decodeCtx(ctx);
        //console.log("app credit granted", sfContext.appCreditGranted);
        //console.log("app credit used", uint256(sfContext.appCreditUsed));
    }

    function onFlowCreated(
        ISuperToken superToken,
        address sender,
        bytes calldata ctx
    ) internal override returns (bytes memory newCtx) {
        if (!isAcceptedSuperToken(superToken)) revert NOT_ACCEPTED_SUPERTOKEN();
        newCtx = ctx;

        int96 inFlowRate = superToken.getFlowRate(sender, address(this));
        int96 referrersOutflowRate = 0;
        int96 specialReferrer1OutFlowRate = 0;
        int96 specialReferrer2OutFlowRate = 0;
        int96 protocolOutFlowRate = 0;
        printAppCredit(ctx);
        bytes memory userData = host.decodeCtx(ctx).userData;
        if (userData.length != 0) {
            UserDataStruct memory parsedUserData = _decodeUserData(userData);
            if (parsedUserData.referrer != sender && referrals[parsedUserData.referrer] != sender) {
                referrals[sender] = parsedUserData.referrer;
                // TODO: what if there's already a referrer set?´
            }
            (referrersOutflowRate, newCtx) = adjustReferrersFlows(sender, 0, inFlowRate, newCtx);
            printAppCredit(newCtx);
            (specialReferrer1OutFlowRate, newCtx) = adjustSpecialReferrerFlow(parsedUserData.specialReferrer1, inFlowRate, newCtx);
            printAppCredit(newCtx);
            (specialReferrer2OutFlowRate, newCtx) = adjustSpecialReferrerFlow(parsedUserData.specialReferrer2, inFlowRate, newCtx);
            printAppCredit(newCtx);
            (protocolOutFlowRate, newCtx) = adjustProtocolFlow(inFlowRate, newCtx);
            printAppCredit(newCtx);
        }

        // see if clipping needs to be applied
        ISuperfluid.Context memory sfContext = host.decodeCtx(newCtx);
        uint256 remainingAppCredit = sfContext.appCreditGranted - uint256(sfContext.appCreditUsed);
        int96 maxRemainingFr = _cfa.getMaximumFlowRateFromDeposit(superToken, remainingAppCredit);
        console.log("max remaining flow rate", uint256(uint96(maxRemainingFr)));
        // The remainder goes to the merchant
        int96 merchantFlowRate = inFlowRate - (referrersOutflowRate + specialReferrer1OutFlowRate + specialReferrer2OutFlowRate + protocolOutFlowRate);
        newCtx = createOrUpdateFlow(
            merchant,
            merchantFlowRate > maxRemainingFr ? maxRemainingFr : merchantFlowRate,
            newCtx
        );
    }

    // TODO
    //function onFlowUpdated
    //function onFlowDeleted


    // =========== Special referrer setup ===========

    struct SpecialReferrerInfo {
        bytes4 cAddr; // compressed address
        uint32 referralFeeSharePM; // fee share per million
        uint8 rType;
    }

    event SpecialReferrerSet(address referrer, bytes4 cAddr, uint32 referralFeeSharePM, uint8 rType);
    mapping (address referrer => SpecialReferrerInfo) public specialReferrerInfos;


    // allows the contract owner to designate special referrers which can be set alongside organic referrers
    // @param rType is just informal, it's up to the frontend to interpret it.
    function setSpecialReferrer(address referrer, uint32 referralFeeSharePM, uint8 rType) external onlyOwner returns (bytes4) {
        bytes4 cAddr = addressCompressor.getOrCreateCAddr(referrer);
        specialReferrerInfos[referrer] = SpecialReferrerInfo(cAddr, referralFeeSharePM, rType);
        emit SpecialReferrerSet(referrer, cAddr, referralFeeSharePM, rType);
        return cAddr;
    }

    // =========== Internal functions ===========

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

    // creates or updates the flow to the protocol fee recipient
    function adjustProtocolFlow(int96 inFlowRate, bytes memory ctx) internal
        returns (int96 addedOutFlowRate, bytes memory newCtx)
    {
        newCtx = ctx;
        addedOutFlowRate = getScaledFlowrate(inFlowRate, PROTOCOL_FEE_PM);
        if (addedOutFlowRate > 0) { // may be 0 due to rounding if numbers get very small
            console.log("adding flow for protocol fee", PROTOCOL_FEE_RECIPIENT, uint256(uint96((addedOutFlowRate))));
            newCtx = createOrUpdateFlow(PROTOCOL_FEE_RECIPIENT, addedOutFlowRate, ctx);
        }
    }

    // resolves the caddr, then creates or updates the flow
    function adjustSpecialReferrerFlow(bytes4 specialReferrerCAddr, int96 inFlowRate, bytes memory ctx) internal
        returns (int96 addedOutFlowRate, bytes memory newCtx) 
    {
        newCtx = ctx;
        address specialReferrer = addressCompressor.getAddress(specialReferrerCAddr);
        if (specialReferrer != address(0)) {
            SpecialReferrerInfo memory specialReferrerInfo = specialReferrerInfos[specialReferrer];
            addedOutFlowRate = getScaledFlowrate(inFlowRate, specialReferrerInfo.referralFeeSharePM);
            if (addedOutFlowRate > 0) { // may be 0 due to rounding if numbers get very small
                console.log("adding flow to special referrer", specialReferrer, uint256(uint96((addedOutFlowRate))));
                newCtx = createOrUpdateFlow(specialReferrer, addedOutFlowRate, ctx);
            }
        }
    }

    /*
    * Create/update flow for referrers according to the fee table.
    * Uses recursion for multi-level referrals.
    * Returns the total flowrate going to referrers.
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
            console.log("adding flow to referrer", referrer, uint256(uint96((referrerFlowRate))));
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