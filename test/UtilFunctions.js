const { BN } = require('@openzeppelin/test-helpers')
const truffleAssert = require('truffle-assertions')
const {
  assertBNEqual,
  BN_ZERO,
  ETH_ADDRESS,
  bn,
  DEC_18,
  increaseTime,
  FOUR_DAYS,
} = require('./utils')
const xSNXCore = artifacts.require('ExtXC')
const TradeAccounting = artifacts.require('ExtTA')
const MockAddressResolver = artifacts.require('MockAddressResolver')
const MockSUSD = artifacts.require('MockSUSD')
const MockWETH = artifacts.require('MockWETH')
const MockUSDC = artifacts.require('MockUSDC')
const MockSynthetix = artifacts.require('MockSynthetix')
const MockSetToken = artifacts.require('MockSetToken')
const MockKyberProxy = artifacts.require('MockKyberProxy')
const MockRewardEscrow = artifacts.require('MockRewardEscrow')
const MockFeePool = artifacts.require('MockFeePool')
const MockCurveFi = artifacts.require('MockCurveFi')
const MockRebalancingModule = artifacts.require('MockRebalancingModule')

contract(
  'xSNXCore, TradeAccounting: Address Setters and Utils',
  async (accounts) => {
    const [deployer, account1, account2, fakeCurveAddress] = accounts
    before(async () => {
      xsnx = await xSNXCore.deployed()
      addressResolver = await MockAddressResolver.deployed()
      susd = await MockSUSD.deployed()
      synthetix = await MockSynthetix.deployed()
      rebalancingModule = await MockRebalancingModule.deployed()
      tradeAccounting = await TradeAccounting.deployed()
      weth = await MockWETH.deployed()
      usdc = await MockUSDC.deployed()
      kyberProxy = await MockKyberProxy.deployed()
      rewardEscrow = await MockRewardEscrow.deployed()
      setToken = await MockSetToken.deployed()
      rewardEscrow = await MockRewardEscrow.deployed()
      feePool = await MockFeePool.deployed()
      curve = await MockCurveFi.deployed()
    })

    describe('Address Setters', async () => {
      // setters executed in deployment script
      // but difficult to test private variable setters directly
      it('should be able to set the Synthetix address on TradeAccounting', async () => {
        await tradeAccounting.setSynthetixAddress()
        assert(true)
      })
      it('should be able to set the Synthetix State address on TradeAccounting', async () => {
        await tradeAccounting.setSynthetixStateAddress()
        assert(true)
      })

      it('should be able to set the xSNX address on TradeAccounting', async () => {
        await tradeAccounting.setInstanceAddress(xsnx.address)
        assert(true)
      })
    })

    describe('ERC20 approvals', async () => {
      // approves executed in deployment script
      it('should approve Kyber to spend SNX belonging to TradeAccounting', async () => {
        const approved = await synthetix.allowance(
          tradeAccounting.address,
          kyberProxy.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })

      it('should approve Kyber to spend sUSD belonging to TradeAccounting', async () => {
        const approved = await susd.allowance(
          tradeAccounting.address,
          kyberProxy.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })

      it('should approve Kyber to spend Set Asset #1 belonging to TradeAccounting', async () => {
        const approved = await weth.allowance(
          tradeAccounting.address,
          kyberProxy.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })

      it('should approve Kyber to spend Set Asset #2 belonging to TradeAccounting', async () => {
        const approved = await usdc.allowance(
          tradeAccounting.address,
          kyberProxy.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })

      // this may be redundant depending on if USDC is one of the Set Assets
      // USDC will need to be approved either way
      it('should approve Kyber to spend USDC belonging to TradeAccounting', async () => {
        const approved = await usdc.allowance(
          tradeAccounting.address,
          kyberProxy.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })

      it('should approve Curve to spend sUSD belonging to TradeAccounting', async () => {
        const approved = await susd.allowance(
          tradeAccounting.address,
          curve.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })

      it('should approve Curve to spend USDC belonging to TradeAccounting', async () => {
        const approved = await usdc.allowance(
          tradeAccounting.address,
          curve.address,
        )
        assert.equal(approved.gt(BN_ZERO), true)
      })
    })

    describe('Vesting', async () => {
      it('should result in greater SNX balance in the contract if executed successfully', async () => {
        const snxBalanceBefore = await tradeAccounting.getSnxBalance()
        await synthetix.transfer(rewardEscrow.address, web3.utils.toWei('2'))
        await rewardEscrow.setSnxAddress(synthetix.address)
        await rewardEscrow.setBalance(web3.utils.toWei('1'))
        await xsnx.vest()
        const snxBalanceAfter = await tradeAccounting.getSnxBalance()

        assertBNEqual(bn(snxBalanceAfter).gt(bn(snxBalanceBefore)), true)
      })
    })

    describe('Collecting Fees', async () => {
      it('should revert if called by non-owner', async () => {
        await truffleAssert.reverts(xsnx.withdrawFees({ from: account1 }))
      })

      it('should result in incremental ETH and sUSD in admin wallet', async () => {
        await setToken.transfer(
          rebalancingModule.address,
          web3.utils.toWei('20'),
        )
        await web3.eth.sendTransaction({
          from: deployer,
          value: web3.utils.toWei('1'),
          to: kyberProxy.address,
        })
        await susd.transfer(synthetix.address, web3.utils.toWei('1000'))
        await weth.transfer(kyberProxy.address, web3.utils.toWei('60'))
        await weth.transfer(rebalancingModule.address, web3.utils.toWei('60'))
        await synthetix.transfer(kyberProxy.address, web3.utils.toWei('1000'))
        await susd.transfer(feePool.address, web3.utils.toWei('20'))
        await susd.transfer(curve.address, web3.utils.toWei('100'))
        await usdc.transfer(curve.address, '100000000')

        await xsnx.mint(0, { value: web3.utils.toWei('0.01') })
        const snxValueHeld = await tradeAccounting.extGetContractSnxValue()
        const amountSusd = bn(snxValueHeld).div(bn(8)) // 800% c-ratio
        const ethAllocation = await tradeAccounting.getEthAllocationOnHedge(
          amountSusd,
        )

        await xsnx.hedge(
          amountSusd,
          ['0', '0'],
          ['0', '0'],
          ethAllocation,
        )

        await xsnx.claim(0, [0, 0], [0, 0], true)

        const contractEthBalBefore = await web3.eth.getBalance(xsnx.address)
        const susdBalBefore = await susd.balanceOf(deployer)

        await xsnx.withdrawFees()

        const contractEthBalAfter = await web3.eth.getBalance(xsnx.address)
        const susdBalAfter = await susd.balanceOf(deployer)

        // testing that the contract dispenses ETH
        // instead of testing that the admin account earns more ETH
        // because gas expense will reduce admin ETH balance and distort test
        assertBNEqual(
          bn(contractEthBalBefore).gt(bn(contractEthBalAfter)),
          true,
        )
        assertBNEqual(bn(susdBalAfter).gt(bn(susdBalBefore)), true)
      })
    })

    describe('Setting manager privilege', async () => {
      it('should be able to set a manager privilege', async () => {
        await xsnx.setManagerAddress(account1)
        assert(true)
      })
      it('should give the manager management privileges', async () => {
        await xsnx.mint(0, { value: web3.utils.toWei('0.01') })

        const snxValueHeld = await tradeAccounting.extGetContractSnxValue()
        const debtBalance = await synthetix.debtBalanceOf(
          xsnx.address,
          web3.utils.fromAscii('sUSD'),
        )
        const amountSusd = bn(snxValueHeld).div(bn(8)).sub(bn(debtBalance))
        const ethAllocation = await tradeAccounting.getEthAllocationOnHedge(
          amountSusd,
        )

        await xsnx.hedge(
          amountSusd,
          [0, 0],
          [0, 0],
          ethAllocation,
          { from: account1 },
        )

        assert(true)
      })

      it('should still exclude non-admins from mgmt privileges', async () => {
        await xsnx.mint(0, { value: web3.utils.toWei('0.01') })
        const snxValueHeld = await tradeAccounting.extGetContractSnxValue()
        const debtBalance = await synthetix.debtBalanceOf(
          xsnx.address,
          web3.utils.fromAscii('sUSD'),
        )
        const amountSusd = bn(snxValueHeld).div(bn(8)).sub(bn(debtBalance))
        const ethAllocation = await tradeAccounting.getEthAllocationOnHedge(
          amountSusd,
        )

        await truffleAssert.reverts(
          xsnx.hedge(amountSusd, [0, 0], [0, 0], ethAllocation, {
            from: account2,
          }),
          'Non-admin caller',
        )
      })
    })

    describe('Curve address setter', async () => {
      it('should allow admin to set Curve address successfully on initial deployment', async () => {
        await tradeAccounting.setCurve(curve.address, 1, 3)
        const snxValueHeld = await tradeAccounting.extGetContractSnxValue()
        const debtBalance = await synthetix.debtBalanceOf(
          xsnx.address,
          web3.utils.fromAscii('sUSD'),
        )
        const amountSusd = bn(snxValueHeld).div(bn(8)).sub(bn(debtBalance))
        const ethAllocation = await tradeAccounting.getEthAllocationOnHedge(
          amountSusd,
        )

        await xsnx.hedge(
          amountSusd,
          ['0', '0'],
          ['0', '0'],
          ethAllocation,
        )

        // tx executed with Curve address successfully
        assert(true)
      })

      it('should not change active Curve address when admin sets next Curve address', async () => {
        // curveFi contract and nextCurveAddress are private vars so we test indirectly
        // fakeCurveAddress is not a Curve mock so if set, hedge tx should fail
        await tradeAccounting.setCurve(fakeCurveAddress, 1, 3)

        await xsnx.mint(0, { value: web3.utils.toWei('0.01') })
        const snxValueHeld = await tradeAccounting.extGetContractSnxValue()
        const debtBalance = await synthetix.debtBalanceOf(
          xsnx.address,
          web3.utils.fromAscii('sUSD'),
        )
        const amountSusd = bn(snxValueHeld).div(bn(8)).sub(bn(debtBalance))
        const ethAllocation = await tradeAccounting.getEthAllocationOnHedge(
          amountSusd,
        )

        await xsnx.hedge(
          amountSusd,
          ['0', '0'],
          ['0', '0'],
          ethAllocation,
        )

        // since hedge tx succeeds, we know old Curve address still in use
        assert(true)
      })

      it('should change active Curve address when addressValidator confirms it', async () => {
        // account1 set as addressValidator in deployment script
        await tradeAccounting.confirmCurveAddress(fakeCurveAddress, {
          from: account1,
        })

        await xsnx.mint(0, { value: web3.utils.toWei('0.01') })
        const snxValueHeld = await tradeAccounting.extGetContractSnxValue()
        const debtBalance = await synthetix.debtBalanceOf(
          xsnx.address,
          web3.utils.fromAscii('sUSD'),
        )
        const amountSusd = bn(snxValueHeld).div(bn(8)).sub(bn(debtBalance))
        const ethAllocation = await tradeAccounting.getEthAllocationOnHedge(
          amountSusd,
        )

        // this should fail because fakeCurveAddress is now active and it isn't a Curve Mock
        await truffleAssert.reverts(
          xsnx.hedge(
            amountSusd,
            ['0', '0'],
            ['0', '0'],
            ethAllocation,
          ),
        )
      })
    })

    describe('Issuance ratio toggle', async() => {
      const targetRatio = 125000000000000000
      it('should read issuance ratio from synthetix state', async() => {
        const issuanceRatio = await tradeAccounting.extGetIssuanceRatio()
        assert.equal(targetRatio, issuanceRatio)
      })
      
      it('should read issuance ratio from system settings', async() => {
        await tradeAccounting.toggleSystemSettingsRead()
        const issuanceRatio = await tradeAccounting.extGetIssuanceRatio()
        assert.equal(targetRatio, issuanceRatio)
      })
    })
  },
)
