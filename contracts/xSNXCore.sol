pragma solidity 0.5.15;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "synthetix/contracts/interfaces/IFeePool.sol";

import "./TradeAccounting.sol";
import "./helpers/Pausable.sol";

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

    uint256 private constant PERCENT = 100;
    uint256 private constant MAX_UINT = 2**256 - 1;
    uint256 private constant BREATHING_PERIOD = 4 hours;
    uint256 private constant LIQUIDATION_WAIT_PERIOD = 6 weeks;

    TradeAccounting private tradeAccounting;
    IAddressResolver private addressResolver;
    IRebalancingSetIssuanceModule private rebalancingModule;

    uint256 public withdrawableEthFees;
    uint256 public withdrawableSusdFees;

    uint256 public lastStakedTimestamp;

    event Mint(
        address indexed user,
        uint256 timestamp,
        uint256 valueSent,
        uint256 mintAmount,
        bool mintWithEth
    );
    event Burn(
        address indexed user,
        uint256 timestamp,
        uint256 burnAmount,
        uint256 valueToSend
    );
    event RebalanceToSnx(uint256 timestamp, uint256 setSold);
    event RebalanceToHedge(uint256 timestamp, uint256 snxSold);
    event WithdrawFees(uint256 ethAmount, uint256 susdAmount);

    struct FeeDivisors {
        uint256 mintFee; // not charged on mintWithSnx
        uint256 burnFee;
        uint256 claimFee;
    }

    FeeDivisors public feeDivisors;

    constructor(
        address payable _tradeAccountingAddress,
        address _setAddress,
        address _snxAddress,
        address _susdAddress
    ) public ERC20Detailed("xSNX", "xSNXa", 18) {
        tradeAccounting = TradeAccounting(_tradeAccountingAddress);
        setAddress = _setAddress;
        snxAddress = _snxAddress;
        susdAddress = _susdAddress;
    }

    /* ========================================================================================= */
    /*                                     Investor-facing                                       */
    /* ========================================================================================= */

    /*
     * @notice Mint new xSNX tokens from the contract by sending ETH
     * @dev Exchanges ETH for SNX
     * @dev Min rate ETH/SNX sourced from Kyber in JS
     * @dev: Calculates overall fund NAV in ETH terms, using implicit
     * ETH/SNX price from Kyber exchange
     * @dev: Mints/distributes new xSNX tokens based on contribution to NAV
     */
    function mint(uint256 minRate) external payable whenNotPaused {
        require(msg.value > 0, "Must send ETH");
        uint256 fee = _administerFee(msg.value, feeDivisors.mintFee);
        uint256 ethUsedForSnx = msg.value.sub(fee);
        uint256 snxBalanceBefore = tradeAccounting.getSnxBalance();

        tradeAccounting.swapEtherToToken.value(ethUsedForSnx)(
            snxAddress,
            minRate
        );

        uint256 mintAmount = tradeAccounting.calculateTokensToMintWithEth(
            snxBalanceBefore,
            ethUsedForSnx,
            totalSupply()
        );

        emit Mint(msg.sender, block.timestamp, msg.value, mintAmount, true);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Mint new xSNX tokens from the contract by sending SNX
     * @notice Won't run without ERC20 approval
     * @dev: Calculates overall fund NAV in ETH terms, using ETH/SNX price (via SNX oracle)
     * @dev: Mints/distributes new xSNX tokens based on contribution to NAV
     */
    function mintWithSnx(uint256 snxAmount) external whenNotPaused {
        require(snxAmount > 0, "Must send SNX");
        uint256 snxBalanceBefore = tradeAccounting.getSnxBalance();
        IERC20(snxAddress).transferFrom(msg.sender, address(this), snxAmount);

        uint256 mintAmount = tradeAccounting.calculateTokensToMintWithSnx(
            snxBalanceBefore,
            snxAmount,
            totalSupply()
        );

        emit Mint(msg.sender, block.timestamp, snxAmount, mintAmount, false);
        return super._mint(msg.sender, mintAmount);
    }

    /*
     * @notice Redeems and burns xSNX tokens and sends ETH to user
     * @dev Checks if ETH reserve is sufficient to settle redeem obligation
     * @dev Will only redeem if ETH reserve is sufficient
     */
    function burn(uint256 tokensToRedeem) external {
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

        uint256 valueToSend = valueToRedeem.sub(
            _administerFee(valueToRedeem, feeDivisors.burnFee)
        );
        super._burn(msg.sender, tokensToRedeem);
        emit Burn(msg.sender, block.timestamp, tokensToRedeem, valueToSend);

        (bool success, ) = msg.sender.call.value(valueToSend)("");
        require(success, "Burn transfer failed");
    }

    /* ========================================================================================= */
    /*                                   Fund Management                                         */
    /* ========================================================================================= */

    /*
     * @notice Hedge strategy management function callable by admin
     * @dev Issues max synths on Synthetix
     * @dev Exchanges sUSD for Set and ETH in terms defined by tradeAccounting.ETH_TARGET
     * @param kyber.getExpectedRate([susd=>eth, susd>currentSetAsset])
     * @param getAssetCurrentlyActiveInSet()
     */
    function hedge(uint256[] calldata minRates, address activeAsset)
        external
        onlyOwner
        whenNotPaused
    {
        _stake();

        uint256 susdBal = getSusdBalance();
        if (susdBal > 0) {
            uint256 ethAllocation = tradeAccounting.getEthAllocationOnHedge(
                susdBal
            );
            _allocateToEth(ethAllocation, minRates[0]);
            _issueMaxSet(minRates[1], activeAsset);
        }
    }

    function _allocateToEth(uint256 _susdValue, uint256 _minRate) private {
        _swapTokenToEther(susdAddress, _susdValue, _minRate);
    }

    function _stake() private {
        lastStakedTimestamp = block.timestamp;
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
            getSusdBalance().div(feeDivisors.claimFee)
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

    /* ========================================================================================= */
    /*                                      Rebalances                                           */
    /* ========================================================================================= */

    /*
     * @notice Called when hedge assets value meaningfully exceeds debt liabilities
     * @dev Hedge assets (Set + ETH) > liabilities (debt) by more than rebalance threshold
     * @param: minRate: kyber.getExpectedRate (currentSetAsset => snx)
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
     * @dev `Liabilities (debt) > assets (Set + ETH)` by more than rebalance threshold
     * @param: totalSusdToBurn: tradeAccounting.getRebalanceTowardsHedgeUtils()
     * @param: activeAsset: getAssetCurrentlyActiveInSet()
     * @param: minRates: kyber.getExpectedRate [activeSetAsset => sUSD, snx => eth]
     * @param: snxToSell: tradeAccounting.getRebalanceTowardsHedgeUtils()
     */
    function rebalanceTowardsHedge(
        uint256 totalSusdToBurn,
        address activeAsset,
        uint256[] calldata minRates,
        uint256 snxToSell
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
     * @param tradeAccounting.()
     * @param getAssetCurrentlyActiveInSet()
     * @param kyber.getExpectedRate(currentSetAsset => ETH)
     */
    function rebalanceSetToEth(
        uint256 redemptionQuantity,
        address activeAsset,
        uint256 minRate
    ) external onlyOwner whenNotPaused {
        _redeemRebalancingSet(redemptionQuantity);
        
        uint activeAssetBalance = getActiveSetAssetBalance();
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

    /*
     * @notice Exit valve to reduce staked position in favor of liquid ETH
     * @notice Unlikely to be called in the normal course of mgmt
     * @dev: Sells Set for SetAsset => sells for sUSD => burns debt => sells SNX for ETH
     */
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

    /*
     * @notice Emergency exit valve to reduce staked position in favor of liquid ETH
     * in the event of operator failure/incapacitation
     * @dev: Params will depend on current C-RATIO, i.e., may not immediately be able
     * to liquidate all debt and SNX
     * @dev: May be callable multiple times as SNX escrow vests
     */
    function liquidationUnwind(
        uint256 totalSusdToBurn,
        uint256[] calldata minRates,
        uint256 snxToSell
    ) external {
        require(
            lastStakedTimestamp.add(LIQUIDATION_WAIT_PERIOD) < block.timestamp,
            "Liquidation not available"
        );

        address activeAsset = getAssetCurrentlyActiveInSet();
        _unwindStakedPosition(
            totalSusdToBurn,
            activeAsset,
            minRates,
            snxToSell
        );
    }

    /*
     * @notice Unlock escrowed SNX rewards
     * @notice Won't be called until at least a year after deployment
     */
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

    // pass ProxyAddressResolver
    function setAddressResolverAddress(address _addressResolver)
        public
        onlyOwner
    {
        addressResolver = IAddressResolver(_addressResolver);
    }

    // function setSusdAddress(address _susdAddress) public onlyOwner {
    //     susdAddress = _susdAddress;
    // }

    // function setSnxAddress(address _snxAddress) public onlyOwner {
    //     snxAddress = _snxAddress;
    // }

    function setRebalancingSetIssuanceModuleAddress(address _rebalancingModule)
        public
        onlyOwner
    {
        rebalancingModule = IRebalancingSetIssuanceModule(_rebalancingModule);
    }

    /* ========================================================================================= */
    /*                                     Set Protocol                                          */
    /* ========================================================================================= */

    function _issueMaxSet(uint256 _minRate, address _activeAsset) private {
        uint256 susdBal = getSusdBalance();
        if (susdBal > 0) {
            _swapTokenToToken(susdAddress, susdBal, _activeAsset, _minRate);
            uint256 issuanceQuantity = tradeAccounting
                .calculateSetIssuanceQuantity();
            rebalancingModule.issueRebalancingSet(
                setAddress,
                issuanceQuantity,
                false
            );
        }
    }

    event RedempQty(uint256 qty);
    event SetBal(uint256 bal);

    function _redeemSet(uint256 _totalSusdToBurn) private {
        uint256 redemptionQuantity = tradeAccounting
            .calculateSetRedemptionQuantity(_totalSusdToBurn);
        emit RedempQty(redemptionQuantity);
        uint256 setBalance = IERC20(setAddress).balanceOf(address(this));
        emit SetBal(setBalance);
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

    function _administerFee(uint256 value, uint256 feeDivisor)
        private
        returns (uint256 fee)
    {
        if (!tradeAccounting.isWhitelisted(msg.sender)) {
            fee = value.div(feeDivisor);
            withdrawableEthFees = withdrawableEthFees.add(fee);
        }
    }

    function setFeeDivisors(
        uint256 _mintFeeDivisor,
        uint256 _burnFeeDivisor,
        uint256 _claimFeeDivisor
    ) public onlyOwner {
        feeDivisors.mintFee = _mintFeeDivisor;
        feeDivisors.burnFee = _burnFeeDivisor;
        feeDivisors.claimFee = _claimFeeDivisor;
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

        emit WithdrawFees(ethFeesToWithdraw, susdFeesToWithdraw);
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
