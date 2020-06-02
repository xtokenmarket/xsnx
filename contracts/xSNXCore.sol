pragma solidity 0.5.15;

import "./TradeAccounting.sol";
import "./helpers/Pausable.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "./interface/Synthetix/IAddressResolver.sol";
import "./interface/Synthetix/IFeePool.sol";
import "./interface/Synthetix/IRewardEscrow.sol";
import "./interface/Synthetix/ISynthetix.sol";

import "./interface/IRebalancingSetIssuanceModule.sol";
import "./interface/IKyberNetworkProxy.sol";


contract xSNXCore is ERC20, ERC20Detailed, Pausable, Ownable {
    address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private susdAddress;
    address private setAddress;
    address private snxAddress;

    bytes32 constant susd = "sUSD";
    bytes32 constant feePoolName = "FeePool";
    bytes32 constant synthetixName = "Synthetix";
    bytes32 constant rewardEscrowName = "RewardEscrow";

    uint256 private constant MAX_UINT = 2**256 - 1;
    uint256 private constant BREATHING_PERIOD = 4 hours;

    uint256 private lastStakedTimestamp;
    uint256 private lastSetToEthRebalance;

    TradeAccounting private tradeAccounting;
    IAddressResolver private addressResolver;
    IRebalancingSetIssuanceModule private rebalancingModule;

    uint256 private feeDivisor;
    uint256 public withdrawableEthFees;
    uint256 public withdrawableSusdFees;

    event Mint(
        address indexed user,
        uint256 timestamp,
        uint256 ethPayable,
        uint256 mintAmount
    );
    event Burn(address indexed user, uint256 timestamp, uint256 burnAmount);
    event RebalanceToSnx(uint256 timestamp, uint256 setSold);
    event RebalanceToHedge(uint256 timestamp, uint256 snxSold);
    event WithdrawEthFee(uint256 amount);
    event WithdrawSusdFee(uint256 amount);

    constructor(address payable _tradeAccountingAddress, address _setAddress)
        public
        ERC20Detailed("xSNX", "xSNXa", 18)
    {
        tradeAccounting = TradeAccounting(_tradeAccountingAddress);
        setAddress = _setAddress;
    }

    /* ========================================================================================= */
    /*                                     Investor-facing                                       */
    /* ========================================================================================= */
    /*
     * @notice Mint new xSNX tokens from the contract by sending ETH
     * @dev Exchanges ETH for SNX
     * @dev Min rate ETH/SNX sourced from Kyber in JS
     * @dev: Calculates overall fund NAV in ETH terms, using ETH/SNX price
     * @dev: Mints/distributes new xSNX tokens based on contribution to NAV
     */
    function _mint(uint256 minRate) external payable whenNotPaused {
        require(msg.value > 0, "Must send ETH");
        uint256 fee = _administerFee(msg.value);
        uint256 ethUsedForSnx = msg.value.sub(fee);
        uint256 snxBalanceBefore = tradeAccounting.getSnxBalance();

        tradeAccounting.swapEtherToToken.value(ethUsedForSnx)(
            snxAddress,
            minRate
        );

        uint256 mintAmount = tradeAccounting.calculateTokensToMint(
            snxBalanceBefore,
            ethUsedForSnx,
            totalSupply()
        );

        emit Mint(msg.sender, block.timestamp, msg.value, mintAmount);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Redeems and burns xSNX tokens and sends ETH to user
     * @dev Checks if ETH reserve is sufficient to settle redeem obligation
     * @dev Will only redeem if ETH reserve is sufficient
     */
    function _burn(uint256 tokensToRedeem) external whenNotPaused {
        require(tokensToRedeem > 0, "Must burn tokens");
        require(
            balanceOf(msg.sender) >= tokensToRedeem,
            "Insufficient balance"
        );

        uint256 valueToRedeem = tradeAccounting.calculateRedemptionValue(
            totalSupply(),
            tokensToRedeem
        );

        require(
            tradeAccounting.getEthBalance() > valueToRedeem,
            "Redeem amount exceeds available liquidity"
        );

        super._burn(msg.sender, tokensToRedeem);
        emit Burn(msg.sender, block.timestamp, tokensToRedeem);
        msg.sender.transfer(valueToRedeem.sub(_administerFee(valueToRedeem)));
    }

    /* ========================================================================================= */
    /*                                   Fund Management                                         */
    /* ========================================================================================= */

    /*
     * @notice Hedge strategy management function callable by anyone
     * @notice Caller is rewarded with 1% of issued synths
     * @dev Issues max synths on Synthetix
     * @dev Exchanges sUSD for Set and ETH in terms defined by tradeAccounting.ETH_TARGET
     */
    function hedge() public whenNotPaused {
        require(
            block.timestamp.sub(lastStakedTimestamp) > BREATHING_PERIOD,
            "Not time to stake yet"
        );
        _stake();

        uint256 susdBal = getSusdBalance();
        if (susdBal > 0) {
            (uint256 tip, uint256 ethAllocation) = tradeAccounting
                .getHedgeUtils(feeDivisor, susdBal);
            IERC20(susdAddress).transfer(msg.sender, tip);

            _allocateToEth(ethAllocation);
            _issueMaxSetWithHelper();
        }
    }

    function _allocateToEth(uint256 susdValue) private {
        uint256 minRate = _getExpectedRate(susdAddress, ETH_ADDRESS, susdValue);
        _swapTokenToEther(susdAddress, susdValue, minRate);
    }

    function _stake() private {
        ISynthetix(addressResolver.getAddress(synthetixName)).issueMaxSynths();
    }

    /*
     * @notice Claims weekly sUSD and SNX rewards
     * @notice Fixes c-ratio if necessary
     * @param susdToBurnToFixCollat tradeAccounting.calculateSusdToBurnToFixRatioExternal()
     * @param minRates[] kyber.getExpectedRate
     * @param feesClaimable feePool.isFeesClaimable(address(this)) - on Synthetix contract
     */
    function claim(
        uint256 susdToBurnToFixCollat,
        uint256[] calldata minRates,
        bool feesClaimable
    ) external onlyOwner {
        IFeePool feePool = IFeePool(addressResolver.getAddress(feePoolName));

        if (!feesClaimable) {
            _redeemSet(susdToBurnToFixCollat);
            _swapTokenToToken(
                getAssetCurrentlyActiveInSet(),
                getActiveSetAssetBalance(),
                susdAddress,
                minRates[0]
            );
            _burnSynths(getSusdBalance());
        }

        feePool.claimFees();
        withdrawableSusdFees = withdrawableSusdFees.add(
            getSusdBalance().div(feeDivisor)
        );
        _swapTokenToEther(susdAddress, getSusdBalance(), minRates[1]);
    }

    function _burnSynths(uint256 amount) private {
        ISynthetix(addressResolver.getAddress(synthetixName)).burnSynths(
            amount
        );
    }

    function _swapTokenToEther(
        address fromToken,
        uint256 amount,
        uint256 minConversionRate
    ) private {
        IERC20(fromToken).transfer(address(tradeAccounting), amount);
        tradeAccounting.swapTokenToEther(fromToken, amount, minConversionRate);
    }

    function _swapTokenToToken(
        address fromToken,
        uint256 amount,
        address toToken,
        uint256 minConversionRate
    ) private {
        IERC20(fromToken).transfer(address(tradeAccounting), amount);
        tradeAccounting.swapTokenToToken(
            fromToken,
            amount,
            toToken,
            minConversionRate
        );
    }

    function _getExpectedRate(
        address fromToken,
        address toToken,
        uint256 amount
    ) private returns (uint256 minRate) {
        (, minRate) = tradeAccounting.getExpectedRate(
            fromToken,
            toToken,
            amount
        );
    }

    /* ========================================================================================= */
    /*                                      Rebalances                                           */
    /* ========================================================================================= */

    /*
     * @notice Called when hedge assets value meaningfully exceeds debt liabilities
     * @dev Hedge assets (Set + ETH) > liabilities (debt) by more than rebalance threshold
     * @param: minRate: kyber.getExpectedRate
     * @param: setToSell: tradeAccounting.getRebalanceTowardsSnxUtils()
     * @param: currentSetAsset: tradeAccounting.getRebalanceTowardsSnxUtils()
     */
    function rebalanceTowardsSnx(
        uint256 minRate,
        uint256 setToSell,
        address currentSetAsset
    ) external onlyOwner {
        require(
            tradeAccounting.isRebalanceTowardsSnxRequired(),
            "Rebalance not necessary"
        );

        _redeemRebalancingSet(setToSell);

        _swapTokenToToken(
            currentSetAsset,
            getActiveSetAssetBalance(),
            snxAddress,
            minRate
        );

        emit RebalanceToSnx(block.timestamp, setToSell);
    }

    /*
     * @notice Called when debt value meaningfully exceeds value of hedge assets
     * @notice Allocates fully to ETH reserve
     * @dev `Liabilities (debt) > assets (Set)` by more than rebalance threshold
     * @param: minRates: kyber.getExpectedRate
     * @param: totalSusdToBurn: tradeAccounting.getRebalanceTowardsHedgeUtils()
     * @param: snxToSell: tradeAccounting.getRebalanceTowardsHedgeUtils()
     * @param: activeAsset: tradeAccounting.getRebalanceTowardsHedgeUtils()
     */
    function rebalanceTowardsHedge(
        uint256[] calldata minRates,
        uint256 totalSusdToBurn,
        uint256 snxToSell,
        address activeAsset
    ) external onlyOwner {
        require(
            tradeAccounting.isRebalanceTowardsHedgeRequired(),
            "Rebalance unnecessary"
        );

        _unwindStakedPosition(
            totalSusdToBurn,
            activeAsset,
            minRates,
            snxToSell
        );
        emit RebalanceToHedge(block.timestamp, snxToSell);
    }

    /*
     * @notice Called whenever ETH bal is less than (hedgeAssets / ETH_TARGET)
     * @dev Rebalances Set holdings to ETH holdings
     */
    function rebalanceSetToEth() external whenNotPaused {
        require(
            block.timestamp.sub(lastSetToEthRebalance) > BREATHING_PERIOD,
            "Not time to rebalance yet"
        );
        uint256 redemptionQuantity = tradeAccounting
            .calculateAssetChangesForRebalanceSetToEth();
        _redeemRebalancingSet(redemptionQuantity);

        address activeAsset = getAssetCurrentlyActiveInSet();
        uint256 activeAssetBalance = getActiveSetAssetBalance();
        uint256 minRate = _getExpectedRate(
            activeAsset,
            ETH_ADDRESS,
            activeAssetBalance
        );

        _swapTokenToEther(activeAsset, activeAssetBalance, minRate);
    }

    function _unwindStakedPosition(
        uint256 totalSusdToBurn,
        address activeAsset,
        uint256[] memory minRates,
        uint256 snxToSell
    ) private {
        _redeemSet(totalSusdToBurn);
        _swapTokenToToken(
            activeAsset,
            getActiveSetAssetBalance(),
            susdAddress,
            minRates[0]
        );
        _burnSynths(getSusdBalance());
        _swapTokenToEther(snxAddress, snxToSell, minRates[1]);
    }

    // partially or fully unwind
    // shouldnt be called in normal course of mgmt
    function unwindStakedPosition(
        uint256 totalSusdToBurn,
        address activeAsset,
        uint256[] calldata minRates,
        uint256 snxToSell
    ) external onlyOwner {
        _unwindStakedPosition(
            totalSusdToBurn,
            activeAsset,
            minRates,
            snxToSell
        );
    }

    function vest() public {
        IRewardEscrow rewardEscrow = IRewardEscrow(
            addressResolver.getAddress(rewardEscrowName)
        );
        require(
            rewardEscrow.totalVestedAccountBalance(address(this)) > 0,
            "No vesting rewards available"
        );
        rewardEscrow.vest();
    }

    /* ========================================================================================= */
    /*                                    Address Setters                                        */
    /* ========================================================================================= */

    function setAddressResolverAddress(address _addressResolver)
        public
        onlyOwner
    {
        addressResolver = IAddressResolver(_addressResolver);
    }

    function setSusdAddress(address _susdAddress) public onlyOwner {
        susdAddress = _susdAddress;
    }

    function setSnxAddress(address _snxAddress) public onlyOwner {
        snxAddress = _snxAddress;
    }

    function setRebalancingSetIssuanceModuleAddress(address _rebalancingModule)
        public
        onlyOwner
    {
        rebalancingModule = IRebalancingSetIssuanceModule(_rebalancingModule);
    }

    /* ========================================================================================= */
    /*                                     Set Protocol                                          */
    /* ========================================================================================= */

    function _issueMaxSetWithHelper() private {
        uint256 minRate = _getExpectedRate(
            susdAddress,
            getAssetCurrentlyActiveInSet(),
            getSusdBalance()
        );
        _issueMaxSet(minRate);
    }

    function _issueMaxSet(uint256 minRate) private {
        uint256 susdBal = getSusdBalance();
        if (susdBal > 0) {
            address activeAsset = getAssetCurrentlyActiveInSet();
            _swapTokenToToken(susdAddress, susdBal, activeAsset, minRate);

            uint256 issuanceQuantity = tradeAccounting
                .calculateSetIssuanceQuantity();
            rebalancingModule.issueRebalancingSet(
                setAddress,
                issuanceQuantity,
                false
            );
        }
    }

    function _redeemSet(uint256 totalSusdToBurn) private {
        uint256 redemptionQuantity = tradeAccounting
            .calculateSetRedemptionQuantity(totalSusdToBurn);
        _redeemRebalancingSet(redemptionQuantity);
    }

    function _redeemRebalancingSet(uint256 redemptionQuantity) private {
        rebalancingModule.redeemRebalancingSet(
            setAddress,
            redemptionQuantity,
            false
        );
    }

    /* ========================================================================================= */
    /*                                        Utils                                              */
    /* ========================================================================================= */

    function getAssetCurrentlyActiveInSet() internal view returns (address) {
        return tradeAccounting.getAssetCurrentlyActiveInSet();
    }

    function getActiveSetAssetBalance() internal view returns (uint256) {
        return tradeAccounting.getActiveSetAssetBalance();
    }

    function getSusdBalance() internal view returns (uint256) {
        return tradeAccounting.getSusdBalance();
    }

    function _administerFee(uint256 value) private returns (uint256 fee) {
        if (!tradeAccounting.isWhitelisted(msg.sender)) {
            fee = value.div(feeDivisor);
            withdrawableEthFees = withdrawableEthFees.add(fee);
        }
    }

    function setFee(uint256 _feeDivisor) public onlyOwner {
        feeDivisor = _feeDivisor;
    }

    function withdrawFees() public onlyOwner {
        require(
            withdrawableEthFees > 0 || withdrawableSusdFees > 0,
            "No fees to withdraw"
        );

        uint256 ethFeesToWithdraw = withdrawableEthFees;
        uint256 susdFeesToWithdraw = withdrawableSusdFees;
        withdrawableEthFees = 0;
        withdrawableSusdFees = 0;

        msg.sender.transfer(ethFeesToWithdraw);
        IERC20(susdAddress).transfer(msg.sender, susdFeesToWithdraw);

        emit WithdrawEthFee(ethFeesToWithdraw);
        emit WithdrawSusdFee(susdFeesToWithdraw);
    }

    // need to approve [snx, susd, setComponentA, setComponentB]
    function approveTradeAccounting(address tokenAddress) public onlyOwner {
        IERC20(tokenAddress).approve(address(tradeAccounting), MAX_UINT);
    }

    // need to approve [setComponentA, setComponentB]
    function approveSetTransferProxy(
        address tokenAddress,
        address transferProxy
    ) public onlyOwner {
        IERC20(tokenAddress).approve(transferProxy, MAX_UINT);
    }

    function() external payable {
        require(msg.sender == address(tradeAccounting), "Must be TA");
    }
}