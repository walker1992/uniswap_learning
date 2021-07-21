pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

import '../libraries/SafeMath.sol';
import '../libraries/UniswapV2Library.sol';
import '../libraries/UniswapV2OracleLibrary.sol';

// sliding window oracle that uses observations collected over a window to provide moving price averages in the past
// `windowSize` with a precision of `windowSize / granularity`
// note this is a singleton oracle and only needs to be deployed once per desired parameters, which
// differs from the simple oracle which must be deployed once per pair.
/*
合约注释（说明）：
    1，滑动视窗采用了观察者模式。观察的窗口大小（时间）为windowSize，精度为windowSize / granularity。
这里granularity字面值是粒度，其实也就是阶段的意思。这里假定windowSize为24小时，也就是观察窗口为24小时。
粒度为8，那么精度为3小时，也就是一个周期内可以记录8次平均价格，从而更容易看出价格趋势。
    2，本合约对于固定的参数来讲，只需要部署一次就行了，是个单例合约。上一篇文章里那个固定视窗模式每个交易对需要部署一个合约。
*/
contract ExampleSlidingWindowOracle {
    using FixedPoint for *;
    using SafeMath for uint;

    struct Observation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }

    address public immutable factory;
    // the desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint public immutable windowSize;
    // the number of observations stored for each pair, i.e. how many price observations are stored for the window.
    // as granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
    // averages are computed over intervals with sizes in the range:
    //   [windowSize - (windowSize / granularity) * 2, windowSize]
    // e.g. if the window size is 24 hours, and the granularity is 24, the oracle will return the average price for
    //   the period:
    //   [now - [22 hours, 24 hours], now]

    uint8 public immutable granularity;
    // this is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    // periodSize = windowSize / granularity，本可以通过以上参数计算periodSize，但为了更直观和节约gas，也记录为一个状态变量
    uint public immutable periodSize;

    // mapping from pair address to a list of price observations of that 
    // 使用一个map来记录每个交易对的观察者。观察者是一个数组，它的长度就是granularity，代表可以观察的次数
    mapping(address => Observation[]) public pairObservations;

    constructor(address factory_, uint windowSize_, uint8 granularity_) public {
        // 验证粒度不能为0，因为要作除数的。虽然不验证时被零除也会报错重置交易，但使用require涵义更明确
        require(granularity_ > 1, 'SlidingWindowOracle: GRANULARITY');
        // 验证观察窗口能被粒度整除，同时给periodSize赋值 
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'SlidingWindowOracle: WINDOW_NOT_EVENLY_DIVISIBLE'
        );
        // 设置状态变量的值（观察参数）。注意，granularity为uint8类型的，也就是一个容器内最多可以记录255次，足够了
        factory = factory_;
        windowSize = windowSize_;
        granularity = granularity_;
    }

    // returns the index of the observation corresponding to the given timestamp
    // 获取给定时间的观察者索引 
    function observationIndexOf(uint timestamp) public view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    // returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationInWindow(address pair) private view returns (Observation storage firstObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        // no overflow issue. if observationIndex + 1 overflows, result is still zero.
        // 为什么会加1呢，因为观察者是循环的，如果最新的索引加1，那么它位置要么为空，要么就有旧值，有旧值就相当于回到了一个窗口周期内最开始的地方。这个函数用于后面的计算中，这样计算时当前区块时间减去这个窗口周期开始的时间，刚好就是一个窗口周期。
        // 这里防止溢出，采用了取模的方式，当然和直接类型转是等同的。这个在核心合约交易对学习时也有提及。最后需要注意的是，因为它是一个私有函数，内部使用。所以返回了一个storage的Observation类型的变量，这样进行传递时就会传递其引用，避免复制对象的开销
        uint8 firstObservationIndex = (observationIndex + 1) % granularity;
        firstObservation = pairObservations[pair][firstObservationIndex];
    }

    // update the cumulative price for the observation at the current timestamp. each observation is updated at most
    // once per epoch period.
    function update(address tokenA, address tokenB) external {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);

        // populate the array with empty observations (first call only)
        // 如果此时交易对的观察者数组未初始化，则使用空数据初始化。初始化后数组的长度就和granularity相同了，所以就不会再初始化第二次
        for (uint i = pairObservations[pair].length; i < granularity; i++) {
            pairObservations[pair].push();
        }

        // get the observation for the current period
        // 获取当前区块记录的观察者信息
        uint8 observationIndex = observationIndexOf(block.timestamp);
        Observation storage observation = pairObservations[pair][observationIndex];

        // we only want to commit updates once per period (i.e. windowSize / granularity)
        // 用来判断这个时间差是否大于指定的精度（一个精度内最多记录一次）。如果满足条件，则通过UniswapV2工具库计算当前区块的价格累计值并更新当前观察者记录。
        // 这样就更新了当前区块观察者的价格累计值及区块时间（如果满足时间间隔要求）。这里还是要注意：观察者是循环利用的，新的会覆盖旧的
        uint timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > periodSize) {
            (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(pair);
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
        }
    }

    // given the cumulative prices of the start and end of a period, and the length of the period, compute the average
    // price in terms of how much amount out is received for the amount in
    // 也是一个私有函数，利用平均价格计算某种资产得到数量。注意，平均价格的计算方式和上一篇文章中提到的一致，也就是价格累计值差除于时间间隔（和计算平均速度的公式相似）
    function computeAmountOut(
        uint priceCumulativeStart, uint priceCumulativeEnd,
        uint timeElapsed, uint amountIn
    ) private pure returns (uint amountOut) {
        // overflow is desired.
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    // returns the amount out corresponding to the amount in for a given token using the moving average over the time
    // range [now - [windowSize, windowSize - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowSize`
    // 查询函数。根据整个窗口期间的平均价格，给定一种代币的数量，计算另一种代币的数量。它的参数分别为输入代币的地址、数量，拟计算的代币的地址
    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut) {
        address pair = UniswapV2Library.pairFor(factory, tokenIn, tokenOut);
        Observation storage firstObservation = getFirstObservationInWindow(pair);

        uint timeElapsed = block.timestamp - firstObservation.timestamp;
        // 验证这个时间差必须小于一个窗口周期，也就是不能太久未更新
        require(timeElapsed <= windowSize, 'SlidingWindowOracle: MISSING_HISTORICAL_OBSERVATION');
        // should never happen.
        // 验证时间差的下限，也不能太久未更新
        require(timeElapsed >= windowSize - periodSize * 2, 'SlidingWindowOracle: UNEXPECTED_TIME_ELAPSED');

        (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(pair);
        (address token0,) = UniswapV2Library.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }
}

/*
注意：
虽然在窗口周期内根据粒度划分了精度（阶段），每个阶段记录了观察者区块时间和当时的累计价格，
它的作用一是用来反映价格滑动，二是可以不用同的累计价格点（非固定，相对于上一篇文章的固定累计价格点）来计算平均价格。
但平均价格还是计算的一整个窗口期的平均价格，而不是一个精度内的平均价格。

每次查询时，查询的窗口期间就会在period上向右滑动一格（一个粒度），所以很形象的叫着滑动窗口。

使用此类预言机必须每个period都必须更新价格累计值，循环往复；否则窗口期间的开始位置在此period时，会出现查询间隔大于窗口期间的情况，
导致查询失败。不过只要再次更新此period的观察者信息，就可以恢复查询了

*/
