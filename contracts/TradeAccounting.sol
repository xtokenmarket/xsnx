pragma solidity 0.5.15;

import "./Whitelist.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "./interface/IxSNXCore.sol";

import "./interface/Synthetix/IRewardEscrow.sol";
import "./interface/Synthetix/IExchangeRates.sol";
import "./interface/Synthetix/IAddressResolver.sol";
import "./interface/Synthetix/ISynthetix.sol";
import "./interface/Synthetix/ISynthetixState.sol";

import "./interface/IKyberNetworkProxy.sol";
import "./interface/ISetAssetBaseCollateral.sol";
import "./interface/ISetToken.sol";


/* 
	xSNX Target Allocation (assuming 800% C-RATIO)
	----------------------
	Allocation         |  NAV   | % NAV
	--------------------------------------
	800 SNX @ $1/token | $800   | 100%
	100 sUSD Debt	   | ($100)	| (12.5%)
	75 USD equiv Set   | $75    | 9.375%
	25 USD equiv ETH   | $25    | 3.125%
	--------------------------------------
	Total                $800   | 100%   
 */

/* 
	Conditions for `isRebalanceTowardsHedgeRequired` to return true
	Assuming 5% rebalance threshold

	Allocation         |  NAV   | % NAV
	--------------------------------------
	800 SNX @ $1/token | $800   | 100.63%
	105 sUSD Debt	   | ($105)	| (13.21%)
	75 USD equiv Set   | $75    | 9.43%
	25 USD equiv ETH   | $25    | 3.14%
	--------------------------------------
	Total                $795   | 100%   

	Debt value		   | $105
	Hedge Assets	   | $100
	-------------------------
	Debt/hedge ratio   | 105%
  */

/* 
	Conditions for `isRebalanceTowardsSnxRequired` to return true
	Assuming 5% rebalance threshold

	Allocation         |  NAV   | % NAV
	--------------------------------------
	800 SNX @ $1/token | $800   | 99.37%
	100 sUSD Debt	   | ($105)	| (12.42%)
	75 USD equiv Set   | $75    | 9.31%
	30 USD equiv ETH   | $30    | 3.72%
	--------------------------------------
	Total                $805   | 100%   

	Hedge Assets	   | $100
	Debt value		   | $105
	-------------------------
	Hedge/debt ratio   | 105%
  */

contract TradeAccounting is Whitelist {
    using SafeMath for uint256;

    uint256 private constant DEC_18 = 1e18;
    uint256 private constant PERCENT = 100;
    uint256 private constant ETH_TARGET = 4;
    uint256 private constant MAX_UINT = 2**256 - 1;
    uint256 private constant REBALANCE_THRESHOLD = 105;
    uint256 private constant INITIAL_SUPPLY_MULTIPLIER = 10;

    ISynthetix private synthetix;
    IExchangeRates private exchangeRates;
    ISynthetixState private synthetixState;
    IAddressResolver private addressResolver;
    IKyberNetworkProxy private kyberNetworkProxy;

    address private caller;

    address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private snxAddress;
    address private setAddress;
    address private susdAddress;

    bytes32 snx = "SNX";
    bytes32 susd = "sUSD";
    bytes32 seth = "sETH";

    bytes32[2] synthSymbols;

    address[2] setComponentAddresses;

    constructor(
        address _setAddress,
        bytes32[2] memory _synthSymbols,
        address[2] memory _setComponentAddresses
    ) public {
        setAddress = _setAddress;
        synthSymbols = _synthSymbols;
        setComponentAddresses = _setComponentAddresses;
    }

    modifier onlyCaller {
        require(msg.sender == caller, "Only xSNX contract can call");
        _;
    }

    /* ========================================================================================= */
    /*                                         Kyber                                             */
    /* ========================================================================================= */

    function swapEtherToToken(address toToken, uint256 minConversionRate)
        public
        payable
        onlyCaller
    {
        kyberNetworkProxy.swapEtherToToken.value(msg.value)(
            ERC20(toToken),
            minConversionRate
        );
        IERC20(toToken).transfer(
            caller,
            IERC20(toToken).balanceOf(address(this))
        );
    }

    function swapTokenToToken(
        address fromToken,
        uint256 amount,
        address toToken,
        uint256 minConversionRate
    ) public onlyCaller {
        kyberNetworkProxy.swapTokenToToken(
            ERC20(fromToken),
            amount,
            ERC20(toToken),
            minConversionRate
        );
        IERC20(toToken).transfer(
            caller,
            IERC20(toToken).balanceOf(address(this))
        );
    }

    function swapTokenToEther(
        address fromToken,
        uint256 amount,
        uint256 minConversionRate
    ) public onlyCaller {
        kyberNetworkProxy.swapTokenToEther(
            ERC20(fromToken),
            amount,
            minConversionRate
        );
        uint256 ethBal = address(this).balance;
        msg.sender.transfer(ethBal);
    }

    function getExpectedRate(
        address fromToken,
        address toToken,
        uint256 amount
    ) public view returns (uint256 expectedRate, uint256 slippageRate) {
        (expectedRate, slippageRate) = kyberNetworkProxy.getExpectedRate(
            ERC20(fromToken),
            ERC20(toToken),
            amount
        );
    }

    /* ========================================================================================= */
    /*                                          NAV                                              */
    /* ========================================================================================= */

    function getEthBalance() public view returns (uint256) {
        uint256 withdrawableFees = IxSNXCore(caller).withdrawableEthFees();
        return address(caller).balance.sub(withdrawableFees);
    }

    // eth terms
    function calculateRedemptionValue(
        uint256 totalSupply,
        uint256 tokensToRedeem
    ) public view returns (uint256 valueToRedeem) {
        uint256 snxBalanceOwned = getSnxBalanceOwned();
        uint256 contractDebtValue = getContractDebtValue();

        uint256 pricePerToken = calculateRedeemTokenPrice(
            tokensToRedeem,
            totalSupply,
            snxBalanceOwned,
            contractDebtValue
        );

        valueToRedeem = pricePerToken.mul(tokensToRedeem).div(DEC_18);
    }

    // eth terms
    function calculateNetAssetValueOnMint(
        uint256 weiPerOneSnx,
        uint256 snxBalanceBefore
    ) internal view returns (uint256) {
        uint256 snxTokenValueInWei = snxBalanceBefore.mul(weiPerOneSnx);
        uint256 nonSnxAssetValue = calculateNonSnxAssetValue();
        uint256 contractDebtValue = getContractDebtValue();
        return snxTokenValueInWei.add(nonSnxAssetValue).sub(contractDebtValue);
    }

    // eth terms
    function calculateNetAssetValueOnRedeem(
        uint256 weiPerOneSnx,
        uint256 snxBalanceOwned,
        uint256 contractDebtValue
    ) internal view returns (uint256) {
        uint256 snxTokenValueInWei = snxBalanceOwned.mul(weiPerOneSnx).div(
            DEC_18
        );
        uint256 nonSnxAssetValue = calculateNonSnxAssetValue();
        return snxTokenValueInWei.add(nonSnxAssetValue).sub(contractDebtValue);
    }

    // eth terms
    function calculateNonSnxAssetValue() internal view returns (uint256) {
        return getSetHoldingsValueInWei().add(getEthBalance());
    }

    // eth terms
    function getWeiPerOneSnx(uint256 snxBalanceBefore, uint256 ethUsedForSnx)
        internal
        view
        returns (uint256 weiPerOneSnx)
    {
        uint256 snxBalanceAfter = getSnxBalance();
        uint256 snxBought = snxBalanceAfter.sub(snxBalanceBefore);
        weiPerOneSnx = ethUsedForSnx.mul(DEC_18).div(snxBought);
    }

    function getActiveAssetSynthSymbol()
        internal
        view
        returns (bytes32 synthSymbol)
    {
        synthSymbol = getAssetCurrentlyActiveInSet() == setComponentAddresses[0]
            ? (synthSymbols[0])
            : (synthSymbols[1]);
    }

    function calculateTokensToMint(
        uint256 snxBalanceBefore,
        uint256 ethUsedForSnx,
        uint256 totalSupply
    ) public view returns (uint256) {
        if (totalSupply == 0) {
            return
                IERC20(snxAddress).balanceOf(caller).mul(
                    INITIAL_SUPPLY_MULTIPLIER
                );
        }

        uint256 weiPerOneSnx = getWeiPerOneSnx(snxBalanceBefore, ethUsedForSnx);
        uint256 pricePerToken = calculateNetAssetValueOnMint(
            weiPerOneSnx,
            snxBalanceBefore
        )
            .div(totalSupply);

        return ethUsedForSnx.mul(DEC_18).div(pricePerToken);
    }

    function calculateRedeemTokenPrice(
        uint256 tokensToRedeem,
        uint256 totalSupply,
        uint256 snxBalanceOwned,
        uint256 contractDebtValue
    ) internal view returns (uint256 pricePerToken) {
        // SNX won't actually be sold but this is a proxy
        // for slippage in calculating redemption price
        uint256 snxToSell = snxBalanceOwned.mul(tokensToRedeem).div(
            totalSupply
        );
        (uint256 weiPerOneSnx, ) = getExpectedRate(
            snxAddress,
            ETH_ADDRESS,
            snxToSell
        );

        uint256 debtValueInWei = calculateDebtValueInWei(contractDebtValue);
        pricePerToken = calculateNetAssetValueOnRedeem(
            weiPerOneSnx,
            snxBalanceOwned,
            debtValueInWei
        )
            .mul(DEC_18)
            .div(totalSupply);
    }

    /* ========================================================================================= */
    /*                                          Set                                              */
    /* ========================================================================================= */

    function getActiveSetAssetBalance() public view returns (uint256) {
        return IERC20(getAssetCurrentlyActiveInSet()).balanceOf(caller);
    }

    function calculateSetQuantity(uint256 componentQuantity)
        public
        view
        returns (uint256 rebalancingSetQuantity)
    {
        uint256 baseSetNaturalUnit = getBaseSetNaturalUnit();
        uint256 baseSetComponentUnits = getBaseSetComponentUnits();
        uint256 baseSetIssuable = componentQuantity.mul(baseSetNaturalUnit).div(
            baseSetComponentUnits
        );

        uint256 rebalancingSetNaturalUnit = getSetNaturalUnit();
        uint256 unitShares = getSetUnitShares();
        rebalancingSetQuantity = baseSetIssuable
            .mul(rebalancingSetNaturalUnit)
            .div(unitShares)
            .mul(99) // ensure sufficient balance in underlying asset
            .div(100)
            .div(rebalancingSetNaturalUnit)
            .mul(rebalancingSetNaturalUnit);
    }

    function calculateSetIssuanceQuantity()
        public
        view
        returns (uint256 rebalancingSetIssuable)
    {
        uint256 componentQuantity = getActiveSetAssetBalance();
        rebalancingSetIssuable = calculateSetQuantity(componentQuantity);
    }

    function calculateSetRedemptionQuantity(uint256 totalSusdToBurn)
        public
        view
        returns (uint256 rebalancingSetRedeemable)
    {
        address currentSetAsset = getAssetCurrentlyActiveInSet();

        (uint256 expectedSetAssetRate, ) = getExpectedRate(
            susdAddress,
            currentSetAsset,
            totalSusdToBurn
        );

        uint256 setAssetCollateralToSell = expectedSetAssetRate
            .mul(totalSusdToBurn)
            .div(DEC_18)
            .mul(103) // err on the high side
            .div(PERCENT);

        uint256 ten = 10;
        uint256 decimals = (ten**ERC20Detailed(currentSetAsset).decimals());
        setAssetCollateralToSell = setAssetCollateralToSell.mul(decimals).div(
            DEC_18
        );

        rebalancingSetRedeemable = calculateSetQuantity(
            setAssetCollateralToSell
        );
    }

    function calculateEthValueOfOneSetUnit()
        internal
        view
        returns (uint256 ethValue)
    {
        uint256 unitShares = getSetUnitShares();
        uint256 rebalancingSetNaturalUnit = getSetNaturalUnit();
        uint256 baseSetRequired = DEC_18.mul(unitShares).div(
            rebalancingSetNaturalUnit
        );

        uint256 unitsOfUnderlying = getBaseSetComponentUnits();
        uint256 baseSetNaturalUnit = getBaseSetNaturalUnit();
        uint256 componentRequired = baseSetRequired.mul(unitsOfUnderlying).div(
            baseSetNaturalUnit
        );

        bytes32 activeAssetSynthSymbol = getActiveAssetSynthSymbol();

        uint256 synthUsd = getSynthPrice(activeAssetSynthSymbol);
        uint256 ethUsd = getSynthPrice(seth);
        ethValue = componentRequired.mul(synthUsd).div(ethUsd);
    }

    function getSetHoldingsValueInWei()
        public
        view
        returns (uint256 setValInWei)
    {
        uint256 setCollateralTokens = getSetCollateralTokens();
        bytes32 synthSymbol = getActiveAssetSynthSymbol();

        uint256 synthUsd = getSynthPrice(synthSymbol);
        uint256 ethUsd = getSynthPrice(seth);
        setValInWei = setCollateralTokens.mul(synthUsd).div(ethUsd);
    }

    function getBaseSetNaturalUnit() internal view returns (uint256) {
        return getCurrentCollateralSet().naturalUnit();
    }

    function getAssetCurrentlyActiveInSet() public view returns (address) {
        address[] memory currentAllocation = getCurrentCollateralSet()
            .getComponents();
        return currentAllocation[0];
    }

    function getCurrentCollateralSet()
        internal
        view
        returns (ISetAssetBaseCollateral)
    {
        return ISetAssetBaseCollateral(getCurrentSet());
    }

    function getCurrentSet() internal view returns (address) {
        return ISetToken(setAddress).currentSet();
    }

    function getSetCollateralTokens() internal view returns (uint256) {
        return
            getSetBalanceCollateral().mul(getBaseSetComponentUnits()).div(
                getSetNaturalUnit()
            );
    }

    function getSetBalanceCollateral() internal view returns (uint256) {
        uint256 unitShares = getSetUnitShares();
        uint256 naturalUnit = getSetNaturalUnit();
        return getContractSetBalance().mul(unitShares).div(naturalUnit);
    }

    function getSetUnitShares() internal view returns (uint256) {
        return ISetToken(setAddress).unitShares();
    }

    function getSetNaturalUnit() internal view returns (uint256) {
        return ISetToken(setAddress).naturalUnit();
    }

    function getContractSetBalance() internal view returns (uint256) {
        return IERC20(setAddress).balanceOf(caller);
    }

    function getBaseSetComponentUnits() internal view returns (uint256) {
        return ISetAssetBaseCollateral(getCurrentSet()).getUnits()[0];
    }

    /* ========================================================================================= */
    /*                                         Synthetix	                                     */
    /* ========================================================================================= */

    function getSusdBalance() public view returns (uint256) {
        uint256 susdBal = IERC20(susdAddress).balanceOf(caller);
        uint256 susdFees = IxSNXCore(caller).withdrawableSusdFees();
        return susdBal.sub(susdFees);
    }

    function getSnxBalance() public view returns (uint256) {
        return getSnxBalanceOwned().add(getSnxBalanceEscrowed());
    }

    function getSnxBalanceOwned() internal view returns (uint256) {
        return IERC20(snxAddress).balanceOf(caller);
    }

    function getSnxBalanceEscrowed() internal view returns (uint256) {
        return
            IRewardEscrow(addressResolver.getAddress(rewardEscrowName))
                .balanceOf(caller);
    }

    function getContractEscrowedSnxValue() internal view returns (uint256) {
        return getSnxBalanceEscrowed().mul(getSnxPrice()).div(DEC_18);
    }

    function getContractOwnedSnxValue() internal view returns (uint256) {
        return getSnxBalanceOwned().mul(getSnxPrice()).div(DEC_18);
    }

    function getSnxPrice() internal view returns (uint256) {
        return exchangeRates.rateForCurrency(snx);
    }

    function getSynthPrice(bytes32 synth) internal view returns (uint256) {
        return exchangeRates.rateForCurrency(synth);
    }

    function calculateDebtValueInWei(uint256 debtValue)
        internal
        view
        returns (uint256 debtBalanceInWei)
    {
        uint256 ethUsd = getSynthPrice(seth);
        debtBalanceInWei = debtValue.mul(DEC_18).div(ethUsd);
    }

    function getContractDebtValue() internal view returns (uint256) {
        return
            ISynthetix(addressResolver.getAddress(synthetixName)).debtBalanceOf(
                caller,
                susd
            );
    }

    function isContractOverCollateralizationRatio() public view returns (bool) {
        if (getCollateralizationRatio() == 0) return true;
        return
            DEC_18.div(getIssuanceRatio()) <
            DEC_18.div(getCollateralizationRatio());
    }

    // returns inverse of contract's C-RATIO
    function getCollateralizationRatio() internal view returns (uint256) {
        if (getSnxBalance() == 0) return 0;
        return
            ISynthetix(addressResolver.getAddress(synthetixName))
                .collateralisationRatio(caller);
    }

    // returns inverse of target C-RATIO
    function getIssuanceRatio() internal view returns (uint256) {
        return synthetixState.issuanceRatio();
    }

    // usd terms
    function getContractSnxValue() internal view returns (uint256) {
        return getSnxBalance().mul(getSnxPrice()).div(DEC_18);
    }

    /* ========================================================================================= */
    /*                                       Burning sUSD                                        */
    /* ========================================================================================= */

    function calculateSusdToBurnToFixRatio(
        uint256 snxValueHeld,
        uint256 contractDebtValue,
        uint256 issuanceRatio
    ) public view returns (uint256) {
        uint256 subtractor = issuanceRatio.mul(snxValueHeld).div(DEC_18);

        if (subtractor > contractDebtValue) return 0;
        return contractDebtValue.sub(subtractor);
    }

    function calculateSusdToBurnToFixRatioExternal()
        public
        view
        returns (uint256)
    {
        uint256 snxValueHeld = getContractSnxValue();
        uint256 debtValue = getContractDebtValue();
        uint256 issuanceRatio = getIssuanceRatio();
        return
            calculateSusdToBurnToFixRatio(
                snxValueHeld,
                debtValue,
                issuanceRatio
            );
    }

    function calculateSusdToBurnToEclipseEscrowed(
        uint256 susdToBurnToFixRatio,
        uint256 issuanceRatio
    ) public view returns (uint256) {
        uint256 escrowedSnxValue = getContractEscrowedSnxValue();
        if (escrowedSnxValue == 0) return 0;

        uint256 snxValue = getContractSnxValue();

        uint256 firstTerm = DEC_18.mul(
            escrowedSnxValue.sub(susdToBurnToFixRatio)
        );
        uint256 secondTerm = issuanceRatio.mul(snxValue.sub(escrowedSnxValue));
        return (firstTerm.sub(secondTerm)).div(DEC_18);
    }

    function calculateSusdToBurnForRedemption(
        uint256 susdToBurnForRatioAndEscrow,
        uint256 tokensToRedeem,
        uint256 totalSupply,
        uint256 contractDebtValue,
        uint256 issuanceRatio
    ) internal view returns (uint256) {
        uint256 latestEstDebt = contractDebtValue.sub(
            susdToBurnForRatioAndEscrow
        );

        uint256 nonEscrowedSnxValue = getContractOwnedSnxValue();
        uint256 snxToSell = getSnxBalanceOwned().mul(tokensToRedeem).div(
            totalSupply
        );
        uint256 valueOfSnxToSell = snxToSell.mul(getSnxPrice()).div(DEC_18);

        uint256 firstTerm = DEC_18.mul(latestEstDebt);
        uint256 secondTerm = issuanceRatio.mul(valueOfSnxToSell);
        uint256 thirdTerm = issuanceRatio.mul(nonEscrowedSnxValue);
        return (firstTerm.add(secondTerm).sub(thirdTerm)).div(DEC_18);
    }

    // function to gauge potential susd input for xsnx.unwindStakedPosition
    function calculateLiquidityRedemptionRequirements(
        uint256 tokensToRedeem,
        uint256 totalSupply
    ) public view returns (uint256 totalSusdToBurn) {
        uint256 snxValueHeld = getContractSnxValue();
        uint256 contractDebtValue = getContractDebtValue();
        uint256 issuanceRatio = getIssuanceRatio();

        uint256 susdToBurnToFixRatio = calculateSusdToBurnToFixRatio(
            snxValueHeld,
            contractDebtValue,
            issuanceRatio
        );

            uint256 susdToBurnToEclipseEscrowed
         = calculateSusdToBurnToEclipseEscrowed(
            susdToBurnToFixRatio,
            issuanceRatio
        );
        uint256 susdToBurnForRedemption = calculateSusdToBurnForRedemption(
            susdToBurnToFixRatio.add(susdToBurnToEclipseEscrowed),
            tokensToRedeem,
            totalSupply,
            contractDebtValue,
            issuanceRatio
        );
        totalSusdToBurn = susdToBurnToFixRatio
            .add(susdToBurnToEclipseEscrowed)
            .add(susdToBurnForRedemption);
    }

    /* ========================================================================================= */
    /*                                        Rebalances                                         */
    /* ========================================================================================= */

    // usd terms
    function calculateAssetChangesForRebalanceToHedge()
        internal
        view
        returns (uint256 totalSusdToBurn, uint256 snxToSell)
    {
        uint256 snxValueHeld = getContractSnxValue();
        uint256 debtValueInUsd = getContractDebtValue();
        uint256 issuanceRatio = getIssuanceRatio();

        uint256 susdToBurnToFixRatio = calculateSusdToBurnToFixRatio(
            snxValueHeld,
            debtValueInUsd,
            issuanceRatio
        );


            uint256 susdToBurnToEclipseEscrowed
         = calculateSusdToBurnToEclipseEscrowed(
            susdToBurnToFixRatio,
            issuanceRatio
        );

        uint256 hedgeAssetsValueInUsd = calculateHedgeAssetsValueInUsd();
        uint256 valueToUnlockInUsd = debtValueInUsd.sub(hedgeAssetsValueInUsd);
        uint256 targetIssuanceRatio = getIssuanceRatio();

        uint256 susdToBurnToUnlockTransfer = valueToUnlockInUsd
            .mul(targetIssuanceRatio)
            .div(DEC_18);

        totalSusdToBurn = (
            susdToBurnToFixRatio.add(susdToBurnToEclipseEscrowed).add(
                susdToBurnToUnlockTransfer
            )
        );
        snxToSell = valueToUnlockInUsd.mul(DEC_18).div(getSnxPrice());
    }

    function calculateAssetChangesForRebalanceToSnx()
        public
        view
        returns (uint256 setToSell)
    {
        (
            uint256 debtValueInWei,
            uint256 hedgeAssetsBalance
        ) = getRebalanceUtils();
        uint256 setValueToSell = hedgeAssetsBalance.sub(debtValueInWei);
        uint256 ethValueOfOneSet = calculateEthValueOfOneSetUnit();
        setToSell = setValueToSell.mul(DEC_18).div(ethValueOfOneSet);

        // Set quantity must be multiple of natural unit
        uint256 naturalUnit = getSetNaturalUnit();
        setToSell = setToSell.div(naturalUnit).mul(naturalUnit);
    }

    function getRebalanceTowardsSnxUtils()
        public
        view
        returns (uint256 setToSell, address activeAsset)
    {
        setToSell = calculateAssetChangesForRebalanceToSnx();
        activeAsset = getAssetCurrentlyActiveInSet();
    }

    // eth terms
    function getRebalanceUtils()
        public
        view
        returns (uint256 debtValueInWei, uint256 hedgeAssetsBalance)
    {
        uint256 setHoldingsInWei = getSetHoldingsValueInWei();
        uint256 ethBalance = getEthBalance();

        uint256 debtValue = getContractDebtValue();
        debtValueInWei = calculateDebtValueInWei(debtValue);
        hedgeAssetsBalance = setHoldingsInWei.add(ethBalance);
    }

    // usd terms
    function calculateHedgeAssetsValueInUsd()
        internal
        view
        returns (uint256 hedgeAssetsValueInUsd)
    {
        uint256 setCollateralTokens = getSetCollateralTokens();
        bytes32 activeAssetSynthSymbol = getActiveAssetSynthSymbol();

        uint256 synthUsd = getSynthPrice(activeAssetSynthSymbol);
        uint256 setValueUsd = setCollateralTokens.mul(synthUsd).div(DEC_18);

        uint256 ethBalance = getEthBalance();
        uint256 ethUsd = getSynthPrice(seth);
        uint256 ethValueUsd = ethBalance.mul(ethUsd).div(DEC_18);

        hedgeAssetsValueInUsd = setValueUsd.add(ethValueUsd);
    }

    function isRebalanceTowardsSnxRequired() public view returns (bool) {
        (
            uint256 debtValueInWei,
            uint256 hedgeAssetsBalance
        ) = getRebalanceUtils();

        if (
            debtValueInWei.mul(REBALANCE_THRESHOLD).div(PERCENT) <
            hedgeAssetsBalance
        ) {
            return true;
        }

        return false;
    }

    function isRebalanceTowardsHedgeRequired() public view returns (bool) {
        (
            uint256 debtValueInWei,
            uint256 hedgeAssetsBalance
        ) = getRebalanceUtils();

        if (
            hedgeAssetsBalance.mul(REBALANCE_THRESHOLD).div(PERCENT) <
            debtValueInWei
        ) {
            return true;
        }

        return false;
    }

    // will fail if !isRebalanceTowardsHedgeRequired()
    function getRebalanceTowardsHedgeUtils()
        public
        view
        returns (
            uint256,
            uint256,
            address
        )
    {
        (
            uint256 totalSusdToBurn,
            uint256 snxToSell
        ) = calculateAssetChangesForRebalanceToHedge();
        address activeAsset = getAssetCurrentlyActiveInSet();
        return (totalSusdToBurn, snxToSell, activeAsset);
    }

    // usd terms
    function getHedgeUtils(uint256 feeDivisor, uint256 susdBal)
        public
        view
        returns (uint256 tip, uint256 ethAllocation)
    {
        tip = susdBal.div(PERCENT);
        susdBal = susdBal.sub(tip);

        uint256 ethUsd = getSynthPrice(seth);

        uint256 setHoldingsInUsd = getSetHoldingsValueInWei().mul(ethUsd).div(
            DEC_18
        );
        uint256 ethBalInUsd = getEthBalance().mul(ethUsd).div(DEC_18);
        uint256 hedgeAssets = setHoldingsInUsd.add(ethBalInUsd);

        if (ethBalInUsd.mul(ETH_TARGET) >= hedgeAssets.add(susdBal)) {
            // full bal directed toward Set
            // eth allocation is 0
        } else if ((ethBalInUsd.add(susdBal)).mul(ETH_TARGET) < hedgeAssets) {
            // full bal directed toward Eth
            ethAllocation = susdBal;
        } else {
            // fractionate allocation
            ethAllocation = ((hedgeAssets.add(susdBal)).div(ETH_TARGET)).sub(
                ethBalInUsd
            );
        }
    }

    // for when eth bal is below eth target
    // eth terms
    function calculateAssetChangesForRebalanceSetToEth()
        public
        view
        returns (uint256 setQuantityToSell)
    {
        uint256 setHoldingsInWei = getSetHoldingsValueInWei();
        uint256 ethBal = getEthBalance();
        uint256 hedgeAssets = setHoldingsInWei.add(ethBal);
        require(
            ethBal.mul(ETH_TARGET) < hedgeAssets,
            "Rebalance not necessary"
        );

        // overcompensates slightly leading to more eth than target
        uint256 ethToAdd = ((hedgeAssets.div(ETH_TARGET)).sub(ethBal));
        setQuantityToSell = getContractSetBalance().mul(ethToAdd).div(
            setHoldingsInWei
        );

        uint256 naturalUnit = getSetNaturalUnit();
        setQuantityToSell = setQuantityToSell.div(naturalUnit).mul(naturalUnit);
    }

    /* ========================================================================================= */
    /*                                     Address Setters                                       */
    /* ========================================================================================= */

    bytes32 constant rewardEscrowName = "RewardEscrow";
    bytes32 constant synthetixStateName = "SynthetixState";
    bytes32 constant exchangeRatesName = "ExchangeRates";
    bytes32 constant synthetixName = "Synthetix";

    function setAddressResolverAddress(address _addressResolver)
        public
        onlyOwner
    {
        addressResolver = IAddressResolver(_addressResolver);
    }

    function setSynthetixStateAddress() public onlyOwner {
        address synthetixStateAddress = addressResolver.getAddress(
            synthetixStateName
        );
        synthetixState = ISynthetixState(synthetixStateAddress);
    }

    function setKyberNetworkAddress(address _kyberNetwork) public onlyOwner {
        kyberNetworkProxy = IKyberNetworkProxy(_kyberNetwork);
    }

    function setCallerAddress(address _caller) public onlyOwner {
        caller = _caller;
    }

    function setSnxAddress(address _snxAddress) public onlyOwner {
        snxAddress = _snxAddress;
    }

    function setSusdAddress(address _susdAddress) public onlyOwner {
        susdAddress = _susdAddress;
    }

    function setExchangeRatesAddress() public onlyOwner {
        address exchangeRatesAddress = addressResolver.getAddress(
            exchangeRatesName
        );
        exchangeRates = IExchangeRates(exchangeRatesAddress);
    }

    /* ========================================================================================= */
    /*                                   		 Utils           		                         */
    /* ========================================================================================= */

    // admin on deployment approve [snx, susd, setComponentA, setComponentB]
    function approveKyber(address tokenAddress) public onlyOwner {
        IERC20(tokenAddress).approve(address(kyberNetworkProxy), MAX_UINT);
    }

    function() external payable {}
}