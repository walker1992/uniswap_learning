pragma solidity =0.6.6;

// 引入库，需要yarn来安装
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

import '../libraries/UniswapV2OracleLibrary.sol';
import '../libraries/UniswapV2Library.sol';

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
// 注释 价格为至少一个周期内的平均值，但是可以使用更长时间的间隔
contract ExampleOracleSimple {
    using FixedPoint for *;

    // 定义平均价格的取值周期，周期太短是无法反映一段时间的平均价格的，这个取值多少可以自己定义。
    // 注意本行中出现的hours是时间单位，就是字面值1小时，转化成秒就是3600秒。当然这里是整数，只是取的数值，没有后面的秒
    uint public constant PERIOD = 24 hours;
    
    // 使用状态变量记录V2交易对的实例和交易对两种代币地址，这表明该合约是某固定交易对的价格预言机
    IUniswapV2Pair immutable pair;
    address public immutable token0;
    address public immutable token1;

    // 记录当前两种代币的累计价格及最后更新区块时间的状态变量
    uint    public price0CumulativeLast;
    uint    public price1CumulativeLast;
    uint32  public blockTimestampLast;

    // 记录两种平均价格的状态变量。注意，价格是个比值，为uq112x112类型（前112位代表整数，后112位代表小数，底层实现是个uint224）
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    constructor(address factory, address tokenA, address tokenB) public {
        IUniswapV2Pair _pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, tokenA, tokenB));
        pair = _pair;
        // 得到的是排过序的代币地址 token0对应的就是price0,amount0,reserve0等等
        token0 = _pair.token0();
        token1 = _pair.token1();
        // 获取当前交易对两种资产（ERC20代币）的价格，注意价格为一个比值
        price0CumulativeLast = _pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        // 获取当前交易对两种资产值及最近更新的区块时间（就是合约部署时最近更新价格的区块时间）。因为使用元组赋值，元组内的变量必须提前定义
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        // 该交易对必须有流动性，不能为空交易对
        require(reserve0 != 0 && reserve1 != 0, 'ExampleOracleSimple: NO_RESERVES'); // ensure that there's liquidity in the pair
    }

    // 更新记录的平均价格
    function update() external {
        // 使用库函数来计算交易对当前区块的两种累计价格和获取当前区块时间，这个为什么使用库函数计算呢，因为交易对的记录的是上一次发生交易所在区块的累计价格和区块时间，并不是当前区块的（因为当前区块可能在查询时还未发生过交易对的交易）。
        // 在UniswapV2OracleLibrary对应的函数中有将这个区块差补上来的逻辑，注意，价格累计在每个交易区块只更新一次
        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
            UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // ensure that at least one full period has passed since the last update
        // 时间间隔必须大于一个周期。必须统计超过一个周期的价格平均值
        require(timeElapsed >= PERIOD, 'ExampleOracleSimple: PERIOD_NOT_ELAPSED');

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        // 更新当前价格平均值（平均价格由累计价格差值除于时间差值得到）。注意FixedPoint.uq112x112()语法代表实例化一个结构。uint224()语法代表类型转换
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    // 价格查询函数，利用当前保存的最新平均价格，输入一种代币的数量（和地址），计算另一种代币的数量
    // 这里计算的结果还有模拟的小数部分，因为最后输出必须为一个整数（代币数量为uint系列类型，没有小数，注意不要和精度的概念弄混），所以调用了decode144()函数，直接将模拟小数的较低112位移走了（右移112位）
    function consult(address token, uint amountIn) external view returns (uint amountOut) {
        if (token == token0) {
            // 注意这里的语法price1Average.mul(amountIn).decode144()中的mul，它不是普通SafeMath中的用于uint的mul，而是FixedPoint中自定义的mul。它返回一个uq144x112，所以才能接着调用decode144函数
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, 'ExampleOracleSimple: INVALID_TOKEN');
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }
}
