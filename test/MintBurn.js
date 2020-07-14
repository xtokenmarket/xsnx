const { BN } = require('@openzeppelin/test-helpers')
const { assertBNEqual, BN_ZERO, toNumber, DEC_18, bn } = require('./utils')
const truffleAssert = require('truffle-assertions')
const xSNXCore = artifacts.require('ExtXC')
const TradeAccounting = artifacts.require('ExtTA')
const MockSynthetix = artifacts.require('MockSynthetix')
const MockKyberProxy = artifacts.require('MockKyberProxy')
const MockExchangeRates = artifacts.require('MockExchangeRates')
const MockSUSD = artifacts.require('MockSUSD')
const MockWETH = artifacts.require('MockWETH')
const MockSetToken = artifacts.require('MockSetToken')
const MockRebalancingModule = artifacts.require('MockRebalancingModule')

contract('xSNXCore: Minting', async (accounts) => {
  const [deployerAccount, account1] = accounts
  const ethValue = web3.utils.toWei('0.1')

  beforeEach(async () => {
    xsnx = await xSNXCore.deployed()
    synthetix = await MockSynthetix.deployed()
    kyberProxy = await MockKyberProxy.deployed()
    tradeAccounting = await TradeAccounting.deployed()
    susd = await MockSUSD.deployed()
    weth = await MockWETH.deployed()
    setToken = await MockSetToken.deployed()
    rebalancingModule = await MockRebalancingModule.deployed()
    exchangeRates = await MockExchangeRates.deployed()
  })

  describe('NAV calculations on issuance', async () => {
    it('should correctly calculate NAV on issuance', async () => {
      const nonSnxAssetValue = await tradeAccounting.extCalculateNonSnxAssetValue()
      const debtValue = await tradeAccounting.extGetContractDebtValue()

      const weiPerOneSnx = web3.utils.toWei('0.01')
      const snxBalanceBefore = web3.utils.toWei('100')
      const snxTokenValueInWei = bn(snxBalanceBefore)
        .mul(bn(weiPerOneSnx))
        .div(bn(DEC_18))

      const navOnMint = await tradeAccounting.extCalculateNetAssetValueOnMint(
        weiPerOneSnx,
        snxBalanceBefore,
      )
      assertBNEqual(
        navOnMint,
        bn(snxTokenValueInWei).add(bn(nonSnxAssetValue)).sub(bn(debtValue)),
      )
    })

    it('should correctly calculate number of tokens to mint with ETH', async () => {
      await synthetix.transfer(kyberProxy.address, web3.utils.toWei('100'))
      await xsnx.mint(0, { value: web3.utils.toWei('0.01') })

      const totalSupply = await xsnx.totalSupply()
      const snxBalanceBefore = await synthetix.balanceOf(xsnx.address)

      const feeDivisor = await xsnx.feeDivisor();
      const snxAmountAcquiredExFee = web3.utils.toWei('10')
      const fee = bn(snxAmountAcquiredExFee).div(bn(feeDivisor))
      const snxAcquired = bn(snxAmountAcquiredExFee).sub(fee)

      await synthetix.transfer(xsnx.address, snxAcquired)
      const snxBalanceAfter = await synthetix.balanceOf(xsnx.address)

      const ethUsedForSnx = web3.utils.toWei('0.1')

      const weiPerOneSnx = await tradeAccounting.extGetWeiPerOneSnx(
        snxBalanceBefore,
        ethUsedForSnx,
      )
      const snxTokenValueInWei = bn(snxBalanceBefore)
        .mul(bn(weiPerOneSnx))
        .div(bn(DEC_18))

      const navOnMint = await tradeAccounting.extCalculateNetAssetValueOnMint(
        weiPerOneSnx,
        snxBalanceBefore,
      )
      const pricePerToken = navOnMint.mul(DEC_18).div(bn(totalSupply))
      const tokensToMint = bn(ethUsedForSnx).mul(DEC_18).div(pricePerToken)

      const contractTokensToMint = await tradeAccounting.calculateTokensToMintWithEth(
        snxBalanceBefore,
        ethUsedForSnx,
        totalSupply,
      )

      assertBNEqual(tokensToMint, contractTokensToMint)
    })

    it('should correctly calculate number of tokens to mint with SNX', async () => {
      const totalSupply = await xsnx.totalSupply()
      const snxBalanceBefore = await synthetix.balanceOf(xsnx.address)
      const snxToSend = web3.utils.toWei('10')

      const snxUsd = await exchangeRates.rateForCurrency(
        web3.utils.fromAscii('SNX'),
      )
      const ethUsd = await exchangeRates.rateForCurrency(
        web3.utils.fromAscii('sETH'),
      )
      const weiPerOneSnx = bn(snxUsd).mul(DEC_18).div(bn(ethUsd))
      const proxyEthUsedForSnx = weiPerOneSnx.mul(bn(snxToSend)).div(DEC_18)

      const pricePerToken = await tradeAccounting.calculateIssueTokenPrice(
        weiPerOneSnx,
        snxBalanceBefore,
        totalSupply
      )

      const expectedTokensToMint = proxyEthUsedForSnx.mul(DEC_18).div(bn(pricePerToken));

      const contractTokensToMint = await tradeAccounting.calculateTokensToMintWithSnx(
        snxBalanceBefore,
        snxToSend,
        totalSupply
      )  
      
      assertBNEqual(expectedTokensToMint, contractTokensToMint)
    })
  })

  describe('Minting xSNX tokens', async () => {
    it('should revert if no ETH is sent', async () => {
      await truffleAssert.reverts(
        xsnx.mint(0, { value: 0, from: account1 }),
        'Must send ETH',
      )
    })

    it('should revert if contract is paused', async () => {
      await xsnx.pause({ from: deployerAccount })
      await truffleAssert.reverts(
        xsnx.mint(0, { value: ethValue, from: account1 }),
        'Pausable: paused',
      )
    })

    it('should buy SNX with ETH', async () => {
      await xsnx.unpause({ from: deployerAccount })
      await synthetix.transfer(kyberProxy.address, web3.utils.toWei('100'))
      await xsnx.mint(0, { value: ethValue, from: account1 })

      const xsnxBalSnx = await synthetix.balanceOf(xsnx.address)
      assert.equal(xsnxBalSnx.gt(BN_ZERO), true)
    })

    it('should issue xSNX token to minter', async () => {
      const xsnxBal = await xsnx.balanceOf(account1)
      assert.equal(xsnxBal.gt(BN_ZERO), true)
    })

    it('should charge an ETH fee on mint equal to fee divisor', async () => {
      const withdrawableFeesBefore = await xsnx.withdrawableEthFees()
      const feeDivisor = await xsnx.feeDivisor()
      await xsnx.mint(0, { value: ethValue })
      const withdrawableFeesAfter = await xsnx.withdrawableEthFees()
      assertBNEqual(
        withdrawableFeesAfter.sub(withdrawableFeesBefore),
        bn(ethValue).div(bn(feeDivisor)),
      )
    })
  })

  describe('NAV calculations on Redemption', async () => {
    // equal to NAV on issuance, less value of escrowed SNX
    it('should correctly calculate NAV on redemption', async () => {
      await setToken.transfer(rebalancingModule.address, web3.utils.toWei('20'))
      await web3.eth.sendTransaction({
        from: deployerAccount,
        value: web3.utils.toWei('1'),
        to: kyberProxy.address,
      })
      await susd.transfer(synthetix.address, web3.utils.toWei('1000'))
      await weth.transfer(kyberProxy.address, web3.utils.toWei('60'))
      await synthetix.transfer(kyberProxy.address, web3.utils.toWei('1000'))
      
      await xsnx.mint(0, { value: web3.utils.toWei('0.01')})
      await xsnx.hedge(['0', '0'])
      const {
        weiPerOneSnx,
        snxBalanceOwned,
        contractDebtValueInWei,
      } = await getCalculateRedeemNavInputs()
      const nonSnxAssetValue = await tradeAccounting.extCalculateNonSnxAssetValue()

      const contractNavOnRedeem = await tradeAccounting.extCalculateNetAssetValueOnRedeem(
        weiPerOneSnx,
        snxBalanceOwned,
        contractDebtValueInWei,
      )

      const snxTokenValueInWei = bn(snxBalanceOwned)
        .mul(bn(weiPerOneSnx))
        .div(DEC_18)
      const navOnRedeem = snxTokenValueInWei
        .add(bn(nonSnxAssetValue))
        .sub(bn(contractDebtValueInWei))

      assertBNEqual(contractNavOnRedeem, navOnRedeem)
    })

    it('should correctly calculate value of ETH to distribute per token redeemed', async () => {
      await setToken.transfer(rebalancingModule.address, web3.utils.toWei('20'))
      await web3.eth.sendTransaction({
        from: deployerAccount,
        value: web3.utils.toWei('1'),
        to: kyberProxy.address,
      })
      await susd.transfer(synthetix.address, web3.utils.toWei('500'))
      await weth.transfer(kyberProxy.address, web3.utils.toWei('60'))
      await synthetix.transfer(kyberProxy.address, web3.utils.toWei('1000'))
      await xsnx.mint(0, { value: web3.utils.toWei('0.01') })
      await xsnx.hedge(['0', '0'])

      const {
        weiPerOneSnx,
        snxBalanceOwned,
        contractDebtValue,
        contractDebtValueInWei,
      } = await getCalculateRedeemNavInputs()

      const navOnRedeem = await tradeAccounting.extCalculateNetAssetValueOnRedeem(
        weiPerOneSnx,
        snxBalanceOwned,
        contractDebtValueInWei,
      )
      const totalSupply = await xsnx.totalSupply()

      const pricePerToken = bn(navOnRedeem).mul(DEC_18).div(bn(totalSupply))
      const contractPricePerToken = await tradeAccounting.extCalculateRedeemTokenPrice(
        totalSupply,
        snxBalanceOwned,
        contractDebtValue,
      )

      assertBNEqual(pricePerToken, contractPricePerToken)
    })

    it('should correctly calculate total redemption value for a given number of tokens', async () => {
      const {
        weiPerOneSnx,
        snxBalanceOwned,
        contractDebtValue,
      } = await getCalculateRedeemNavInputs()

      const totalSupply = await xsnx.totalSupply()
      const tokensToRedeem = bn(totalSupply).div(bn(1000))
      const pricePerToken = await tradeAccounting.extCalculateRedeemTokenPrice(
        totalSupply,
        snxBalanceOwned,
        contractDebtValue,
      )
      const valueToRedeem = bn(pricePerToken).mul(tokensToRedeem).div(DEC_18)

      const contractValueToRedeem = await tradeAccounting.calculateRedemptionValue(
        totalSupply,
        tokensToRedeem,
      )
      assertBNEqual(valueToRedeem, contractValueToRedeem)
    })
  })

  // describe('Burning tokens on redemption', async () => {
  //   it('should send the correct amount of ETH based on tokens burned', async () => {
  //     await setToken.transfer(rebalancingModule.address, web3.utils.toWei('20'))
  //     await web3.eth.sendTransaction({
  //       from: deployerAccount,
  //       value: web3.utils.toWei('1'),
  //       to: kyberProxy.address,
  //     })
  //     await susd.transfer(synthetix.address, web3.utils.toWei('1000'))
  //     await weth.transfer(kyberProxy.address, web3.utils.toWei('60'))
  //     await synthetix.transfer(kyberProxy.address, web3.utils.toWei('500'))
  //     await xsnx.mint(0, { value: web3.utils.toWei('0.01'), from: account1 })
  //     const account1Bal = await xsnx.balanceOf(account1)

  //     const ethBalBefore = await web3.eth.getBalance(account1)
  //     const totalSupply = await xsnx.totalSupply()
  //     const tokensToRedeem = bn(account1Bal).div(bn(100))

  //     const {
  //       weiPerOneSnx,
  //       snxBalanceOwned,
  //       contractDebtValue,
  //     } = await getCalculateRedeemNavInputs()
  //     const pricePerToken = await tradeAccounting.extCalculateRedeemTokenPrice(
  //       totalSupply,
  //       snxBalanceOwned,
  //       contractDebtValue,
  //     )
  //     let valueToRedeem = bn(pricePerToken).mul(tokensToRedeem).div(DEC_18)
  //     const feeDivisor = await xsnx.feeDivisor()
  //     const fee = bn(valueToRedeem).div(bn(feeDivisor))
  //     valueToRedeem = valueToRedeem.sub(fee)

  //     await xsnx.burn(tokensToRedeem)

  //     // setTimeout is a hack to account for this truffle bug
  //     // https://github.com/trufflesuite/ganache-cli/issues/7
  //     setTimeout(async () => {
  //       const ethBalAfter = await web3.eth.getBalance(account1)
  //       console.log('ethBalBefore', ethBalBefore.toString())
  //       console.log('ethBalAfter', ethBalAfter.toString())
  //       console.log('valueToRedeem', valueToRedeem.toString())

  //       assertBNEqual(bn(ethBalBefore).add(valueToRedeem), bn(ethBalAfter))
  //     }, 2000)
  //   })
  // })
})

const getWeiPerOneSnxOnRedemption = async () => {
  const SLIPPAGE = bn(99)
  const PERCENT = bn(100)
  const ethUsd = await exchangeRates.rateForCurrency(
    web3.utils.fromAscii('sETH'),
  )
  const snxUsd = await exchangeRates.rateForCurrency(
    web3.utils.fromAscii('SNX'),
  )
  const weiPerOneSnx = bn(snxUsd)
    .mul(DEC_18)
    .div(bn(ethUsd))
    .mul(SLIPPAGE)
    .div(PERCENT)
  return weiPerOneSnx
}

const getCalculateRedeemNavInputs = async () => {
  const weiPerOneSnx = await getWeiPerOneSnxOnRedemption()
  const snxBalanceOwned = await tradeAccounting.extGetSnxBalanceOwned()
  const contractDebtValue = await tradeAccounting.extGetContractDebtValue()
  const contractDebtValueInWei = await tradeAccounting.extCalculateDebtValueInWei(
    contractDebtValue,
  )

  return {
    weiPerOneSnx,
    snxBalanceOwned,
    contractDebtValue,
    contractDebtValueInWei,
  }
}
