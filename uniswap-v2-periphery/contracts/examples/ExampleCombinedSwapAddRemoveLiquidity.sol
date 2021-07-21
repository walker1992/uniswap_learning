// 本合约源码不在周边合约uniswap-v2-periphery的master分支下，而是位于swap-before-liquidity-events分支下。所在目录为examples目录

pragma solidity =0.6.6;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/lib/contracts/libraries/Babylonian.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "../interfaces/IUniswapV2Router01.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IERC20.sol";
import "../libraries/SafeMath.sol";
import "../libraries/UniswapV2Library.sol";

// enables adding and removing liquidity with a single token to/from a pair
// adds liquidity via a single token of the pair, by first swapping against the pair and then adding liquidity
// removes liquidity in a single token, by removing liquidity and then immediately swapping
contract ExampleCombinedSwapAddRemoveLiquidity {
    using SafeMath for uint;

    IUniswapV2Factory public immutable factory;
    IUniswapV2Router01 public immutable router;
    IWETH public immutable weth;

    constructor(IUniswapV2Factory factory_, IUniswapV2Router01 router_, IWETH weth_) public {
        factory = factory_;
        router = router_;
        weth = weth_;
    }

    // grants unlimited approval for a token to the router unless the existing allowance is high enough
    function approveRouter(address _token, uint256 _amount) internal {
        uint256 allowance = IERC20(_token).allowance(address(this), address(router));
        if (allowance < _amount) {
            if (allowance > 0) {
                // clear the existing allowance
                TransferHelper.safeApprove(_token, address(router), 0);
            }
            TransferHelper.safeApprove(_token, address(router), uint256(-1));
        }
    }

    // returns the amount of token that should be swapped in such that ratio of reserves in the pair is equivalent
    // to the swapper's ratio of tokens
    // note this depends only on the number of tokens the caller wishes to swap and the current reserves of that token,
    // and not the current reserves of the other token
    // 计算单资产注入时用户需要先分离多少资产先进行交换。它的两个输入参数分别为当前交易对中某种资产数量和用户欲注入的单资产数量
    function calculateSwapInAmount(uint reserveIn, uint userIn) public pure returns (uint) {
        return Babylonian.sqrt(reserveIn.mul(userIn.mul(3988000) + reserveIn.mul(3988009))).sub(reserveIn.mul(1997)) / 1994;
    }

    // internal function shared by the ETH/non-ETH versions
    /*
    * 入参：
    * from是从本合约还是从哪转移资产。
    * tokenIn与otherToken。交易对中单资产注入的代币地址及另一种代币地址。
    * amountIn，用户拟注入的总数量，其中一部分会先进行交易，兑换成另一种代币。
    * minOtherTokenIn，中间过程兑换成另一种代币的最小数量`。
    * to，接收流动性地址。
    * deadline，最晚交易时间
    * 出参：
    * amountTokenIn，拟注入的单资产中，参与交易（兑换）部分的数量。
    * amountTokenOther，中间过程兑换成另一种代币的数量。
    * liquidity，最后得到的流动性。
    */
    function _swapExactTokensAndAddLiquidity(
        address from,
        address tokenIn,
        address otherToken,
        uint amountIn,
        uint minOtherTokenIn,
        address to,
        uint deadline
    ) internal returns (uint amountTokenIn, uint amountTokenOther, uint liquidity) {
        // compute how much we should swap in to match the reserve ratio of tokenIn / otherToken of the pair
        uint swapInAmount;
        {
            (uint reserveIn,) = UniswapV2Library.getReserves(address(factory), tokenIn, otherToken);
            swapInAmount = calculateSwapInAmount(reserveIn, amountIn);
        }

        // 如果拟注入的资产来源不是本合约，就先将所有拟注入的资产转移到本合约（这样本合约就有相应资产了）。这个过程中会需要授权转移。
        // first take possession of the full amount from the caller, unless caller is this contract
        if (from != address(this)) {
            TransferHelper.safeTransferFrom(tokenIn, from, address(this), amountIn);
        }
        // approve for the swap, and then later the add liquidity. total is amountIn
        // 本合约对注入的资产进行授权，授权对象为路由合约，授权额度为拟注入的资产数量
        approveRouter(tokenIn, amountIn);
        // 调用Router合约的swapExactTokensForTokens方法，将swapInAmount数量的注入资产兑换成另一种资产。
        // 注意接收地址为本地址，因为接下来还要用接收的另一种资产实现提供流动性功能。后面为什么还有一个[1]呢，
        // 因为swapExactTokensForTokens函数返回的是两种代币的参与数量，是一个数组。数组内元素顺序和交易路径一致，
        // 所以[1]代表得到的另一种资产数量
        {
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = otherToken;

            amountTokenOther = router.swapExactTokensForTokens(
                swapInAmount,
                minOtherTokenIn,
                path,
                address(this),
                deadline
            )[1];
        }
        
        // approve the other token for the add liquidity call
        // 对得到的另一种资产也进行授权（不然提供流动性时Router合约无法转移走）。授权对象为Router合约，额度就是得到的另一种资产数量（也是注入数量）
        approveRouter(otherToken, amountTokenOther);
        amountTokenIn = amountIn.sub(swapInAmount);

        // no need to check that we transferred everything because minimums == total balance of this contract
        (,,liquidity) = router.addLiquidity(
            tokenIn,
            otherToken,
        // desired amountA, amountB
            amountTokenIn,
            amountTokenOther,
        // amountTokenIn and amountTokenOther should match the ratio of reserves of tokenIn to otherToken
        // thus we do not need to constrain the minimums here
            0,
            0,
            to,
            deadline
        );
    }

    // computes the exact amount of tokens that should be swapped before adding liquidity for a given token
    // does the swap and then adds liquidity
    // minOtherToken should be set to the minimum intermediate amount of token1 that should be received to prevent
    // excessive slippage or front running
    // liquidity provider shares are minted to the 'to' address
    // 用户实际调用的外部接口，欲注入的单向资产为普通ERC20代币。此时，直接调用_swapExactTokensAndAddLiquidity函数即可
    function swapExactTokensAndAddLiquidity(
        address tokenIn,
        address otherToken,
        uint amountIn,
        uint minOtherTokenIn,
        address to,
        uint deadline
    ) external returns (uint amountTokenIn, uint amountTokenOther, uint liquidity) {
        return _swapExactTokensAndAddLiquidity(
            msg.sender, tokenIn, otherToken, amountIn, minOtherTokenIn, to, deadline
        );
    }

    // similar to the above method but handles converting ETH to WETH
    // 用户实际调用的外部接口，欲注入的单向资产为ETH。因为用户欲注入的资产为ETH，所以UniswapV2交易对必定为WETH/ERC20交易对。
    // 这个函数和上面的函数相比，仅多了一个将ETH兑换成WETH的步骤，其它几乎完全一样。注意到因为兑换后的WETH在本合约（不在用户身上），
    // 所以调用_swapExactTokensAndAddLiquidity函数时第一个参数为address(this)
    function swapExactETHAndAddLiquidity(
        address token,
        uint minTokenIn,
        address to,
        uint deadline
    ) external payable returns (uint amountETHIn, uint amountTokenIn, uint liquidity) {
        weth.deposit{value: msg.value}();
        return _swapExactTokensAndAddLiquidity(
            address(this), address(weth), token, msg.value, minTokenIn, to, deadline
        );
    }

    // internal function shared by the ETH/non-ETH versions
    // undesiredToken: 另外一种资产
    // desiredToken: 自己最后想要的资产
    function _removeLiquidityAndSwap(
        address from,
        address undesiredToken,
        address desiredToken,
        uint liquidity,
        uint minDesiredTokenOut,
        address to,
        uint deadline
    ) internal returns (uint amountDesiredTokenOut) {
        address pair = UniswapV2Library.pairFor(address(factory), undesiredToken, desiredToken);
        // take possession of liquidity and give access to the router
        TransferHelper.safeTransferFrom(pair, from, address(this), liquidity);
        approveRouter(pair, liquidity);

        (uint amountInToSwap, uint amountOutToTransfer) = router.removeLiquidity(
            undesiredToken,
            desiredToken,
            liquidity,
        // amount minimums are applied in the swap
            0,
            0,
        // contract must receive both tokens because we want to swap the undesired token
            address(this),
            deadline
        );

        // send the amount in that we received in the burn
        approveRouter(undesiredToken, amountInToSwap);

        address[] memory path = new address[](2);
        path[0] = undesiredToken;
        path[1] = desiredToken;

        uint amountOutSwap = router.swapExactTokensForTokens(
            amountInToSwap,
        // we must get at least this much from the swap to meet the minDesiredTokenOut parameter
            minDesiredTokenOut > amountOutToTransfer ? minDesiredTokenOut - amountOutToTransfer : 0,
            path,
            to,
            deadline
        )[1];

        // we do this after the swap to save gas in the case where we do not meet the minimum output
        if (to != address(this)) {
            TransferHelper.safeTransfer(desiredToken, to, amountOutToTransfer);
        }
        amountDesiredTokenOut = amountOutToTransfer + amountOutSwap;
    }

    // burn the liquidity and then swap one of the two tokens to the other
    // enforces that at least minDesiredTokenOut tokens are received from the combination of burn and swap
    function removeLiquidityAndSwapToToken(
        address undesiredToken,
        address desiredToken,
        uint liquidity,
        uint minDesiredTokenOut,
        address to,
        uint deadline
    ) external returns (uint amountDesiredTokenOut) {
        return _removeLiquidityAndSwap(
            msg.sender, undesiredToken, desiredToken, liquidity, minDesiredTokenOut, to, deadline
        );
    }

    // only WETH can send to this contract without a function call.
    receive() payable external {
        require(msg.sender == address(weth), 'CombinedSwapAddRemoveLiquidity: RECEIVE_NOT_FROM_WETH');
    }

    // similar to the above method but for when the desired token is WETH, handles unwrapping
    function removeLiquidityAndSwapToETH(
        address token,
        uint liquidity,
        uint minDesiredETH,
        address to,
        uint deadline
    ) external returns (uint amountETHOut) {
        // do the swap remove and swap to this address
        amountETHOut = _removeLiquidityAndSwap(
            msg.sender, token, address(weth), liquidity, minDesiredETH, address(this), deadline
        );

        // now withdraw to ETH and forward to the recipient
        weth.withdraw(amountETHOut);
        TransferHelper.safeTransferETH(to, amountETHOut);
    }
}
