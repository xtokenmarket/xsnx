pragma solidity 0.5.15;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";

import "synthetix/contracts/interfaces/IFeePool.sol";

import "./TradeAccounting.sol";

import "./interface/IRebalancingSetIssuanceModule.sol";
import "./interface/IxSNX.sol";

contract xSNXAdmin is Ownable {
    using SafeMath for uint256;

    address
        private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private susdAddress;
    address private setAddress;
    address private snxAddress;
    address private setTransferProxy;

    address private xsnxTokenAddress;

    address private manager;

    bytes32 constant susd = "sUSD";

    bytes32 constant feePoolName = "FeePool";
    bytes32 constant synthetixName = "Synthetix";
    bytes32 constant rewardEscrowName = "RewardEscrow";

    uint256 private constant MAX_UINT = 2**256 - 1;
    uint256 private constant LIQUIDATION_WAIT_PERIOD = 3 weeks;

    ISynthetix private synthetix;
    TradeAccounting private tradeAccounting;
    IAddressResolver private addressResolver;
    IRebalancingSetIssuanceModule private rebalancingModule;

    uint256 public lastClaimedTimestamp;

    event RebalanceToSnx(uint256 timestamp, uint256 setSold);
    event RebalanceToHedge(uint256 timestamp, uint256 snxSold);

    function initialize(
        address payable _tradeAccountingAddress,
        address _setAddress,
        address _snxAddress,
        address _susdAddress,
        address _setTransferProxy,
        address _addressResolver,
        address _rebalancingModule,
        address _ownerAddress
    ) public initializer {
        Ownable.initialize(_ownerAddress);

        //Set parameters
        tradeAccounting = TradeAccounting(_tradeAccountingAddress);
        setAddress = _setAddress;
        snxAddress = _snxAddress;
        susdAddress = _susdAddress;
        setTransferProxy = _setTransferProxy;
        addressResolver = IAddressResolver(_addressResolver);
        rebalancingModule = IRebalancingSetIssuanceModule(_rebalancingModule);

        lastClaimedTimestamp = block.timestamp;
    }

    /*
     * @notice Function to transfer ETH to token contract on burn
     * @dev Issues synths on Synthetix
     * @param valueToSend: token burn redemption value
     */
    function sendEthOnRedemption(uint256 valueToSend) public onlyTokenContract {
        (bool success, ) = xsnxTokenAddress.call.value(valueToSend)("");
        require(success, "Redeem transfer failed");
    }

    /* ========================================================================================= */
    /*                                   Fund Management                                         */
    /* ========================================================================================= */

    /*
     * @notice Hedge strategy management function callable by admin
     * @dev Issues synths on Synthetix
     * @dev Exchanges sUSD for Set and ETH in terms defined by tradeAccounting.ETH_TARGET
     * @param mintAmount: susd to mint
     * @param minKyberRates: kyber.getExpectedRate([usdc=>eth, usdc=>currentSetAsset])
     * @param minCurveReturns: curve.get_dy_underlying([(ethAllocation, susd=>usdc), ((mintAmount.sub(ethAllocation)), susd>usdc)])
     * @param ethAllocation: tradeAccounting.getEthAllocationOnHedge(mintAmount)
     */
    function hedge(
        uint256 mintAmount,
        uint256[] calldata minKyberRates,
        uint256[] calldata minCurveReturns,
        uint256 ethAllocation
    ) external onlyOwnerOrManager {
        _stake(mintAmount);

        _allocateToEth(ethAllocation, minKyberRates[0], minCurveReturns[0]);

        address activeAsset = getAssetCurrentlyActiveInSet();
        _issueMaxSet(
            mintAmount.sub(ethAllocation),
            minKyberRates[1],
            activeAsset,
            minCurveReturns[1]
        );
    }

    function _allocateToEth(
        uint256 _susdValue,
        uint256 _minKyberRate,
        uint256 _minCurveReturn
    ) private {
        _swapTokenToEther(
            susdAddress,
            _susdValue,
            _minKyberRate,
            _minCurveReturn
        );
    }

    function _stake(uint256 mintAmount) private {
        ISynthetix(addressResolver.getAddress(synthetixName)).issueSynths(
            mintAmount
        );
    }

    /*
     * @notice Claims weekly sUSD and SNX rewards
     * @notice Fixes c-ratio if necessary
     * @param susdToBurnToFixCollat: tradeAccounting.calculateSusdToBurnToFixRatioExternal()
     * @param minKyberRates[]: kyber.getExpectedRate[setAsset => usdc, usdc => eth]
     * @param minCurveReturns: curve.get_dy_underlying([(setAssetBalance, usdc=>susd), (susdBalance susd=>usdc)])
     * @param feesClaimable: feePool.isFeesClaimable(address(this)) - on Synthetix contract
     */
    function claim(
        uint256 susdToBurnToFixCollat,
        uint256[] calldata minKyberRates,
        uint256[] calldata minCurveReturns,
        bool feesClaimable
    ) external onlyOwnerOrManager {
        lastClaimedTimestamp = block.timestamp;

        if (!feesClaimable) {
            _redeemSet(susdToBurnToFixCollat);
            _swapTokenToToken(
                getAssetCurrentlyActiveInSet(),
                getActiveSetAssetBalance(),
                susdAddress,
                minKyberRates[0],
                minCurveReturns[0]
            );
            _burnSynths(getSusdBalance());
        }

        IFeePool(addressResolver.getAddress(feePoolName)).claimFees();

        // fee collection
        uint256 feeDivisor = IxSNX(xsnxTokenAddress).getClaimFeeDivisor();
        IERC20(susdAddress).transfer(
            xsnxTokenAddress,
            getSusdBalance().div(feeDivisor)
        );

        _swapTokenToEther(
            susdAddress,
            getSusdBalance(),
            minKyberRates[1],
            minCurveReturns[1]
        );
    }

    function _burnSynths(uint256 _amount) private {
        ISynthetix(addressResolver.getAddress(synthetixName)).burnSynths(
            _amount
        );
    }

    function _swapTokenToEther(
        address _fromToken,
        uint256 _amount,
        uint256 _minKyberRate,
        uint256 _minCurveReturn
    ) private {
        if (_amount > 0) {
            IERC20(_fromToken).transfer(address(tradeAccounting), _amount);
            tradeAccounting.swapTokenToEther(
                _fromToken,
                _amount,
                _minKyberRate,
                _minCurveReturn
            );
        }
    }

    function _swapTokenToToken(
        address _fromToken,
        uint256 _amount,
        address _toToken,
        uint256 _minKyberRate,
        uint256 _minCurveReturn
    ) private {
        IERC20(_fromToken).transfer(address(tradeAccounting), _amount);
        tradeAccounting.swapTokenToToken(
            _fromToken,
            _amount,
            _toToken,
            _minKyberRate,
            _minCurveReturn
        );
    }

    /* ========================================================================================= */
    /*                                      Rebalances                                           */
    /* ========================================================================================= */

    /*
     * @notice Called when hedge assets value meaningfully exceeds debt liabilities
     * @dev Hedge assets (Set + ETH) > liabilities (debt) by more than rebalance threshold
     * @param: minRate: kyber.getExpectedRate(activeAsset=>snx)
     */
    function rebalanceTowardsSnx(uint256 minRate) external onlyOwnerOrManager {
        require(
            tradeAccounting.isRebalanceTowardsSnxRequired(),
            "Rebalance unnnecessary"
        );
        (uint256 setToSell, address activeAsset) = tradeAccounting
            .getRebalanceTowardsSnxUtils();

        _redeemRebalancingSet(setToSell);

        _swapTokenToToken(
            activeAsset,
            getActiveSetAssetBalance(),
            snxAddress,
            minRate,
            0
        );

        emit RebalanceToSnx(block.timestamp, setToSell);
    }

    /*
     * @notice Called when debt value meaningfully exceeds value of hedge assets
     * @notice Allocates fully to ETH reserve
     * @dev `Liabilities (debt) > assets (Set + ETH)` by more than rebalance threshold
     * @param: totalSusdToBurn: tradeAccounting.getRebalanceTowardsHedgeUtils()
     * @param: minKyberRates: kyber.getExpectedRate([activeSetAsset => usdc, snx => eth])
     * @param minCurveReturns: curve.get_dy_underlying([(expectedUsdcBalance, usdc=>susd), (0)])
     * @param: snxToSell: tradeAccounting.getRebalanceTowardsHedgeUtils()
     */
    function rebalanceTowardsHedge(
        uint256 totalSusdToBurn,
        uint256[] calldata minKyberRates,
        uint256[] calldata minCurveReturns,
        uint256 snxToSell
    ) external onlyOwnerOrManager {
        require(
            tradeAccounting.isRebalanceTowardsHedgeRequired(),
            "Rebalance unnecessary"
        );

        address activeAsset = getAssetCurrentlyActiveInSet();
        _unwindStakedPosition(
            totalSusdToBurn,
            activeAsset,
            minKyberRates,
            minCurveReturns,
            snxToSell
        );
        emit RebalanceToHedge(block.timestamp, snxToSell);
    }

    /*
     * @notice Callable whenever ETH bal is less than (hedgeAssets / ETH_TARGET)
     * @dev Rebalances Set holdings to ETH holdings
     * @param minRate: kyber.getExpectedRate(activeAsset => ETH)
     */
    function rebalanceSetToEth(uint256 minRate) external onlyOwnerOrManager {
        uint256 redemptionQuantity = tradeAccounting
            .calculateSetToSellForRebalanceSetToEth();
        _redeemRebalancingSet(redemptionQuantity);

        address activeAsset = getAssetCurrentlyActiveInSet();
        uint256 activeAssetBalance = getActiveSetAssetBalance();
        _swapTokenToEther(activeAsset, activeAssetBalance, minRate, 0);
    }

    function _unwindStakedPosition(
        uint256 _totalSusdToBurn,
        address _activeAsset,
        uint256[] memory _minKyberRates,
        uint256[] memory _minCurveReturns,
        uint256 _snxToSell
    ) private {
        if (_totalSusdToBurn > 0) {
            _redeemSet(_totalSusdToBurn);
            _swapTokenToToken(
                _activeAsset,
                getActiveSetAssetBalance(),
                susdAddress,
                _minKyberRates[0],
                _minCurveReturns[0]
            );
            _burnSynths(getSusdBalance());
        }

        _swapTokenToEther(snxAddress, _snxToSell, _minKyberRates[1], 0);
    }

    /*
     * @notice Exit valve to reduce staked position in favor of liquid ETH
     * @notice Unlikely to be called in the normal course of mgmt
     * @params: refer to `rebalanceToHedge` for descriptions, however params here are discretionary
     */
    function unwindStakedPosition(
        uint256 totalSusdToBurn,
        uint256[] calldata minKyberRates,
        uint256[] calldata minCurveReturns,
        uint256 snxToSell
    ) external onlyOwnerOrManager {
        address activeAsset = getAssetCurrentlyActiveInSet();
        _unwindStakedPosition(
            totalSusdToBurn,
            activeAsset,
            minKyberRates,
            minCurveReturns,
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
        uint256[] calldata minKyberRates,
        uint256[] calldata minCurveReturns,
        uint256 snxToSell
    ) external {
        require(
            lastClaimedTimestamp.add(LIQUIDATION_WAIT_PERIOD) < block.timestamp,
            "Liquidation not available"
        );

        address activeAsset = getAssetCurrentlyActiveInSet();
        _unwindStakedPosition(
            totalSusdToBurn,
            activeAsset,
            minKyberRates,
            minCurveReturns,
            snxToSell
        );

        uint256 susdBalRemaining = getSusdBalance();
        _swapTokenToEther(susdAddress, susdBalRemaining, 0, 0);
    }

    /*
     * @notice Unlock escrowed SNX rewards
     * @notice Won't be called until at least a year after deployment
     */
    function vest() public {
        IRewardEscrow rewardEscrow = IRewardEscrow(
            addressResolver.getAddress(rewardEscrowName)
        );
        rewardEscrow.vest();
    }

    /* ========================================================================================= */
    /*                                     Set Protocol                                          */
    /* ========================================================================================= */

    function _issueMaxSet(
        uint256 _susdAmount,
        uint256 _minRate,
        address _activeAsset,
        uint256 _minCurveReturn
    ) private {
        _swapTokenToToken(
            susdAddress,
            _susdAmount,
            _activeAsset,
            _minRate,
            _minCurveReturn
        );

        uint256 issuanceQuantity = tradeAccounting
            .calculateSetIssuanceQuantity();
        rebalancingModule.issueRebalancingSet(
            setAddress,
            issuanceQuantity,
            false
        );
    }

    function _redeemSet(uint256 _totalSusdToBurn) private {
        uint256 redemptionQuantity = tradeAccounting
            .calculateSetRedemptionQuantity(_totalSusdToBurn);
        _redeemRebalancingSet(redemptionQuantity);
    }

    function _redeemRebalancingSet(uint256 _redemptionQuantity) private {
        rebalancingModule.redeemRebalancingSet(
            setAddress,
            _redemptionQuantity,
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

    function setXsnxTokenAddress(address _xsnxTokenAddress) public onlyOwner {
        if (xsnxTokenAddress == address(0)) {
            xsnxTokenAddress = _xsnxTokenAddress;
        }
    }

    function setManagerAddress(address _manager) public onlyOwner {
        manager = _manager;
    }

    modifier onlyOwnerOrManager {
        require(isOwner() || msg.sender == manager, "Non-admin caller");
        _;
    }

    modifier onlyTokenContract {
        require(msg.sender == xsnxTokenAddress, "Non token caller");
        _;
    }

    // approve [setComponentA, setComponentB] on deployment
    function approveSetTransferProxy(address tokenAddress) public onlyOwner {
        IERC20(tokenAddress).approve(setTransferProxy, MAX_UINT);
    }

    function() external payable {
        require(msg.sender == address(tradeAccounting), "Incorrect sender");
    }
}
