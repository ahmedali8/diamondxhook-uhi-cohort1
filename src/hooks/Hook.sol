// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {BaseHook} from "../forks/BaseHook.sol";

contract Hook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    error AddLiquidityThroughHook();
    error LAMMBertInvariantCheckFailed();

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    uint256 public constant C = 8; // liquidity concentration parameter

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Don't allow adding liquidity normally
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Override how swaps are done
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function calculateOutput(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 constantC)
        public
        pure
        returns (uint256 amountOut)
    {
        console2.log("amountIn: ", amountIn); // 100000000000000000000
        console2.log("reserveIn: ", reserveIn); // 1000000000000000000000
        console2.log("reserveOut: ", reserveOut); // 1000000000000000000000
        console2.log("constantC: ", constantC); // 8

        // Actual formula:
        // note: vice verse for x and y
        //   y = (W(ce^(2c - cx))) / c
        // where x is amountIn, y is amountOut

        // Step 1: Calculate the numerator for the exponential term
        // numerator = c * reserveOut
        uint256 numerator = constantC * reserveOut;
        console2.log("numerator: ", numerator); // 8000000000000000000000

        // Step 2: Calculate the denominator for the exponential term
        // denominator = reserveIn + amountIn
        uint256 denominator = reserveIn + amountIn;
        console2.log("denominator: ", denominator); // 1100000000000000000000

        // Step 3: Calculate the exponential term
        // expTerm = e^(c * reserveOut / (reserveIn + amountIn))
        uint256 innerTerm = FixedPointMathLib.divWad(numerator, denominator);
        console2.log("innerTerm: ", innerTerm); // 727272727272727272727

        int256 expTerm = FixedPointMathLib.expWad(int256(innerTerm));
        console2.log("expTerm: ", expTerm); // 1440473665311697751864

        // Step 4: Apply the Lambert W function to the exponential term
        // wValue = W(expTerm)
        int256 wValue = FixedPointMathLib.lambertW0Wad(expTerm);
        console2.log("wValue: ", wValue); // 5557566873012694094

        // Step 5: Calculate the output amount
        // amountOut = (wValue - (c * reserveIn)) / c
        amountOut = FixedPointMathLib.divWad(uint256(wValue * 1e18) - constantC * reserveIn, constantC * 1e34);
        console2.log("amountOut: ", amountOut); // 69469585912658576175
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(abi.encode(CallbackData(amountEach, key.currency0, key.currency1, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external override poolManagerOnly returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData)); // TODO: pass the c as well

        // Settle `amountEach` of each currency from the sender
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );
        callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

        // Calculate new reserves
        uint256 newReserve0 = callbackData.currency0.balanceOf(address(poolManager)) + callbackData.amountEach;
        uint256 newReserve1 = callbackData.currency1.balanceOf(address(poolManager)) + callbackData.amountEach;

        // if c is zero then the formula converts to CPMM
        // as the c becomes larger and larger then it becomes CSMM
        // Check the equation c(x + y) + ln(x * y) = 2c
        //
        // Calculate the left hand side
        uint256 lhs = C.mulWad(newReserve0 + newReserve1)
            + uint256(FixedPointMathLib.lnWad(int256(newReserve0.mulWad(newReserve1))));

        // Calculate the right hand side
        uint256 rhs = 2 * C * 1e18;

        if (lhs >= rhs) {
            revert LAMMBertInvariantCheckFailed();
        }

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of each currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our hook can be used by minting/burning claim tokens the hook owns
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);

        return "";
    }

    // Swapping
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 100000000000000000000 (100e18)
        uint256 amountInOutPositive =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Retrieve the current reserves
        // uint256 reserve0 = key.currency0.balanceOf(address(poolManager));
        // uint256 reserve1 = key.currency1.balanceOf(address(poolManager));

        uint256 amountOut;
        if (params.zeroForOne) {
            // If user is selling Token 0 (specifiedCurrency) and buying Token 1 (unspecifiedCurrency)
            amountOut = calculateOutput(
                amountInOutPositive,
                key.currency0.balanceOf(address(poolManager)),
                key.currency1.balanceOf(address(poolManager)),
                C
            );
        } else {
            // If user is selling Token 1 (specifiedCurrency) and buying Token 0 (unspecifiedCurrency)
            amountOut = calculateOutput(
                amountInOutPositive,
                key.currency1.balanceOf(address(poolManager)),
                key.currency0.balanceOf(address(poolManager)),
                C
            );
        }

        /**
         * BalanceDelta is a packed value of (currency0Amount, currency1Amount)
         *
         *         BeforeSwapDelta varies such that it is not sorted by token0 and token1
         *         Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"
         *
         *         Specified Currency => The currency in which the user is specifying the amount they're swapping for
         *         Unspecified Currency => The other currency
         *
         *         For example, in an ETH/USDC pool, there are 4 possible swap cases:
         *
         *         1. ETH for USDC with Exact Input for Output (amountSpecified = negative value representing ETH)
         *         2. ETH for USDC with Exact Output for Input (amountSpecified = positive value representing USDC)
         *         3. USDC for ETH with Exact Input for Output (amountSpecified = negative value representing USDC)
         *         4. USDC for ETH with Exact Output for Input (amountSpecified = positive value representing ETH)
         *
         *         In Case (1):
         *             -> the user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
         *             -> the unspecifiedCurrency is USDC
         *
         *         In Case (2):
         *             -> the user is specifying their swap amount in terms of USDC, so the specifiedCurrency is USDC
         *             -> the unspecifiedCurrency is ETH
         *
         *         In Case (3):
         *             -> the user is specifying their swap amount in terms of USDC, so the specifiedCurrency is USDC
         *             -> the unspecifiedCurrency is ETH
         *
         *         In Case (4):
         *             -> the user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
         *             -> the unspecifiedCurrency is USDC
         *
         * To implement the Lambert AMM logic:
         *
         * 1. Retrieve the current reserves of the pool.
         * 2. Calculate the output amount using the custom Lambert AMM formula:
         *    - For zeroForOne swaps (Token 0 for Token 1), use the reserves of Token 0 and Token 1.
         *    - For oneForZero swaps (Token 1 for Token 0), use the reserves of Token 1 and Token 0.
         * 3. Update the BeforeSwapDelta based on the calculated output amount.
         * 4. Handle debits and credits accordingly:
         *    - Debit the specified currency from the user to the Pool Manager.
         *    - Credit the unspecified currency from the Pool Manager to the user.
         */
        console2.log("int128(int256(amountOut)): ", int128(int256(amountOut)));
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // Specified amount (input delta)
            int128(params.amountSpecified >= 0 ? int256(amountOut) : -int256(amountOut)) // Unspecified amount (output delta)
        );

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take claim tokens for that Token 0 from the PM and keep it in the hook
            // and create an equivalent credit for that Token 0 since it is ours!
            key.currency0.take(
                poolManager, address(this), params.amountSpecified >= 0 ? amountOut : amountInOutPositive, true
            );

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!
            key.currency1.settle(
                poolManager, address(this), params.amountSpecified >= 0 ? amountInOutPositive : amountOut, true
            );
        } else {
            key.currency0.settle(poolManager, address(this), amountInOutPositive, true);
            key.currency1.take(poolManager, address(this), amountOut, true);
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }
}
