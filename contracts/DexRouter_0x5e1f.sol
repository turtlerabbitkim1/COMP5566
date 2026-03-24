// File: contracts/8/DexRouter.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./UnxswapRouter.sol";
import "./UnxswapV3Router.sol";

import "./interfaces/IWETH.sol";
import "./interfaces/IApproveProxy.sol";
import "./interfaces/IWNativeRelayer.sol";

import "./libraries/PMMLib.sol";
import "./libraries/CommissionLib.sol";
import "./libraries/EthReceiver.sol";
import "./libraries/UniswapTokenInfoHelper.sol";
import "./libraries/CommonLib.sol";

import "./DagRouter.sol";


/// @title DexRouterV1
/// @notice Entrance of Split trading in Dex platform
/// @dev Entrance of Split trading in Dex platform
contract DexRouter is
    EthReceiver,
    UnxswapRouter,
    UnxswapV3Router,
    CommissionLib,
    UniswapTokenInfoHelper,
    DagRouter
{
    string public constant version = "v1.0.7-multi-commission";
    using UniversalERC20 for IERC20;

    //-------------------------------
    //------- Modifier --------------
    //-------------------------------
    /// @notice Ensures a function is called before a specified deadline.
    /// @param deadLine The UNIX timestamp deadline.
    modifier isExpired(uint256 deadLine) {
        require(deadLine >= block.timestamp, "Route: expired");
        _;
    }

    //-------------------------------
    //------- Internal Functions ----
    //-------------------------------
    /// @notice Executes multiple adapters for a transaction pair.
    /// @param payer The address of the payer.
    /// @param to The address of the receiver.
    /// @param batchAmount The amount to be transferred in each batch.
    /// @param path The routing path for the swap.
    /// @param noTransfer A flag to indicate whether the token transfer should be skipped.
    /// @dev It includes checks for the total weight of the paths and executes the swapping through the adapters.
    function _exeForks(
        address payer,
        address refundTo,
        address to,
        uint256 batchAmount,
        RouterPath memory path,
        bool noTransfer
    ) private {
        uint256 totalWeight;
        for (uint256 i = 0; i < path.mixAdapters.length; i++) {
            bytes32 rawData = bytes32(path.rawData[i]);
            address poolAddress;
            bool reverse;
            {
                uint256 weight;
                assembly {
                    poolAddress := and(rawData, _ADDRESS_MASK)
                    reverse := and(rawData, _REVERSE_MASK)
                    weight := shr(160, and(rawData, _WEIGHT_MASK))
                }
                totalWeight += weight;
                if (i == path.mixAdapters.length - 1) {
                    require(
                        totalWeight <= 10_000,
                        "totalWeight can not exceed 10000 limit"
                    );
                }

                if (!noTransfer) {
                    uint256 _fromTokenAmount = weight == 10_000
                        ? batchAmount
                        : (batchAmount * weight) / 10_000;
                    if (_fromTokenAmount > 0) {
                        _transferInternal(
                            payer,
                            path.assetTo[i],
                            path.fromToken,
                            _fromTokenAmount
                        );
                    }
                }
            }

            _exeAdapter(
                reverse,
                path.mixAdapters[i],
                to,
                poolAddress,
                path.extraData[i],
                refundTo
            );
        }
    }
    /// @notice Executes a series of swaps or operations defined by a set of routing paths, potentially across different protocols or pools.
    /// @param payer The address providing the tokens for the swap.
    /// @param receiver The address receiving the output tokens.
    /// @param isToNative Indicates whether the final asset should be converted to the native blockchain asset (e.g., ETH).
    /// @param batchAmount The total amount of the input token to be swapped.
    /// @param hops An array of RouterPath structures, each defining a segment of the swap route.
    /// @dev This function manages complex swap routes that might involve multiple hops through different liquidity pools or swapping protocols.
    /// It iterates through the provided `hops`, executing each segment of the route in sequence.

    function _exeHop(
        address payer,
        address refundTo,
        address receiver,
        bool isToNative,
        uint256 batchAmount,
        RouterPath[] memory hops
    ) private {
        address fromToken = _bytes32ToAddress(hops[0].fromToken);
        bool toNext;
        bool noTransfer;

        // execute hop
        uint256 hopLength = hops.length;
        for (uint256 i = 0; i < hopLength; ) {
            if (i > 0) {
                fromToken = _bytes32ToAddress(hops[i].fromToken);
                batchAmount = _getBalanceOf(fromToken, address(this));
                payer = address(this);
            }

            address to = address(this);
            if (i == hopLength - 1 && !isToNative) {
                to = receiver;
            } else if (i < hopLength - 1 && hops[i + 1].assetTo.length == 1) {
                to = hops[i + 1].assetTo[0];
                toNext = true;
            } else {
                toNext = false;
            }

            // 3.2 execute forks
            _exeForks(payer, refundTo, to, batchAmount, hops[i], noTransfer);
            noTransfer = toNext;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Executes a complex swap based on provided parameters and paths.
    /// @param baseRequest Basic swap details including tokens, amounts, and deadline.
    /// @param batchesAmount Amounts for each swap batch.
    /// @param batches Detailed swap paths for execution.
    /// @param payer Address providing the tokens.
    /// @param receiver Address receiving the swapped tokens.

    function _smartSwapInternal(
        BaseRequest memory baseRequest,
        uint256[] memory batchesAmount,
        RouterPath[][] memory batches,
        address payer,
        address refundTo,
        address receiver
    ) private {
        // 1. transfer from token in
        BaseRequest memory _baseRequest = baseRequest;

        address fromToken = _bytes32ToAddress(_baseRequest.fromToken);

        // In order to deal with ETH/WETH transfer rules in a unified manner,
        // we do not need to judge according to fromToken.
        if (UniversalERC20.isETH(IERC20(fromToken))) {
            IWETH(_WETH).deposit{
                value: _baseRequest.fromTokenAmount
            }();
            require(_bytes32ToAddress(batches[0][0].fromToken) == _WETH, "firstToken mismatch");
            payer = address(this);
        } else {
            require(_bytes32ToAddress(batches[0][0].fromToken) == fromToken, "firstToken mismatch");
        }

        // 2. check total batch amount
        {
            // avoid stack too deep
            uint256 totalBatchAmount;
            for (uint256 i = 0; i < batchesAmount.length; ) {
                totalBatchAmount += batchesAmount[i];
                unchecked {
                    ++i;
                }
            }
            require(
                totalBatchAmount <= _baseRequest.fromTokenAmount,
                "Route: number of batches should be <= fromTokenAmount"
            );
        }

        // 4. execute batch
        // check length, fix DRW-02: LACK OF LENGTH CHECK ON BATATCHES
        require(batchesAmount.length == batches.length, "length mismatch");
        for (uint256 i = 0; i < batches.length; ) {
            if (i > 0) {
                require(batches[i][0].fromToken == batches[0][0].fromToken, "Inconsistent fromToken across batches");
            }
            
            // execute hop, if the whole swap replacing by pmm fails, the funds will return to dexRouter
            _exeHop(
                payer,
                refundTo,
                receiver,
                IERC20(_baseRequest.toToken).isETH(),
                batchesAmount[i],
                batches[i]
            );
            unchecked {
                ++i;
            }
        }

        // 5. transfer tokens to user
        _transferTokenToUser(_baseRequest.toToken, receiver);
    }

    //-------------------------------
    //------- Users Functions -------
    //-------------------------------

    /// @notice Executes a smart swap based on the given order ID, supporting complex multi-path swaps. For smartSwap, if fromToken or toToken is ETH, the address needs to be 0xEeee.
    /// @param orderId The unique identifier for the swap order, facilitating tracking and reference.
    /// @param baseRequest Struct containing the base parameters for the swap, including the source and destination tokens, amount, minimum return, and deadline.
    /// @param batchesAmount An array specifying the amount to be swapped in each batch, allowing for split operations.
    /// @param batches An array of RouterPath structs defining the routing paths for each batch, enabling swaps through multiple protocols or liquidity pools.
    /// @return returnAmount The total amount of destination tokens received from executing the swap.
    /// @dev This function orchestrates a swap operation that may involve multiple steps, routes, or protocols based on the provided parameters.
    /// It's designed to ensure flexibility and efficiency in finding the best swap paths.

    function smartSwapByOrderId(
        uint256 orderId,
        BaseRequest calldata baseRequest,
        uint256[] calldata batchesAmount,
        RouterPath[][] calldata batches,
        PMMLib.PMMSwapRequest[] calldata // extraData
    )
        external
        payable
        isExpired(baseRequest.deadLine)
        returns (uint256 returnAmount)
    {
        emit SwapOrderId(orderId);
        return
            _smartSwapTo(
                msg.sender,
                msg.sender,
                msg.sender,
                baseRequest,
                batchesAmount,
                batches
            );
    }
    /// @notice Executes a token swap using the Unxswap protocol based on a specified order ID.
    /// @param srcToken The source token involved in the swap.
    /// @param amount The amount of the source token to be swapped.
    /// @param minReturn The minimum amount of tokens expected to be received to ensure the swap does not proceed under unfavorable conditions.
    /// @param pools An array of pool identifiers specifying the pools to use for the swap, allowing for optimized routing.
    /// @return returnAmount The amount of destination tokens received from the swap.
    /// @dev This function allows users to perform token swaps based on predefined orders, leveraging the Unxswap protocol's liquidity pools. It ensures that the swap meets the user's specified minimum return criteria, enhancing trade efficiency and security.

    function unxswapByOrderId(
        uint256 srcToken,
        uint256 amount,
        uint256 minReturn,
        // solhint-disable-next-line no-unused-vars
        bytes32[] calldata pools
    ) external payable returns (uint256 returnAmount) {
        return unxswapTo(
            srcToken,
            amount,
            minReturn,
            msg.sender,
            pools
        );
    }
    /// @notice Executes a swap tailored for investment purposes, adjusting swap amounts based on the contract's balance.
    /// @param baseRequest Struct containing essential swap parameters like source and destination tokens, amounts, and deadline.
    /// @param batchesAmount Array indicating how much of the source token to swap in each batch, facilitating diversified investments.
    /// @param batches Detailed routing information for executing the swap across different paths or protocols.
    /// @param extraData Additional data for swaps, supporting protocol-specific requirements.
    /// @param to The address where the swapped tokens will be sent, typically an investment contract or pool.
    /// @return returnAmount The total amount of destination tokens received, ready for investment.
    /// @dev This function is designed for scenarios where investments are made in batches or through complex paths to optimize returns. Adjustments are made based on the contract's current token balance to ensure precise allocation.

    function smartSwapByInvest( // change function name
        BaseRequest memory baseRequest,
        uint256[] memory batchesAmount,
        RouterPath[][] memory batches,
        PMMLib.PMMSwapRequest[] memory extraData,
        address to
    ) external payable returns (uint256 returnAmount) {
        return
            smartSwapByInvestWithRefund(
                baseRequest,
                batchesAmount,
                batches,
                extraData,
                to,
                to
            );
    }
    function smartSwapByInvestWithRefund(
        BaseRequest memory baseRequest,
        uint256[] memory batchesAmount,
        RouterPath[][] memory batches,
        PMMLib.PMMSwapRequest[] memory, // extraData
        address to,
        address refundTo
    )
        public
        payable
        isExpired(baseRequest.deadLine)
        returns (uint256 returnAmount)
    {
        address fromToken = _bytes32ToAddress(baseRequest.fromToken);
        require(fromToken != _ETH, "Invalid source token");
        require(refundTo != address(0), "refundTo is address(0)");
        require(to != address(0), "to is address(0)");
        require(baseRequest.fromTokenAmount > 0, "fromTokenAmount is 0");
        uint256 amount = IERC20(fromToken).balanceOf(address(this));
        for (uint256 i = 0; i < batchesAmount.length; ) {
            batchesAmount[i] =
                (batchesAmount[i] * amount) /
                baseRequest.fromTokenAmount;
            unchecked {
                ++i;
            }
        }
        baseRequest.fromTokenAmount = amount;

        returnAmount = _getBalanceOf(baseRequest.toToken, to);
        _smartSwapInternal(
            baseRequest,
            batchesAmount,
            batches,
            address(this), // payer
            refundTo, // refundTo
            to // receiver
        );
        // check minReturnAmount
        returnAmount =
            _getBalanceOf(baseRequest.toToken, to) -
            returnAmount;
        require(
            returnAmount >= baseRequest.minReturnAmount,
            "Min return not reached"
        );
        emit OrderRecord(
            fromToken,
            baseRequest.toToken,
            tx.origin,
            baseRequest.fromTokenAmount,
            returnAmount
        );
    }

    /// @notice Executes a swap using the Uniswap V3 protocol.
    /// @param receiver The address that will receive the swap funds.
    /// @param amount The amount of the source token to be swapped.
    /// @param minReturn The minimum acceptable amount of tokens to receive from the swap, guarding against excessive slippage.
    /// @param pools An array of pool identifiers used to define the swap route within Uniswap V3.
    /// @return returnAmount The amount of tokens received after the completion of the swap.
    /// @dev This function wraps and unwraps ETH as required, ensuring the transaction only accepts non-zero `msg.value` for ETH swaps. It invokes `_uniswapV3Swap` to execute the actual swap and handles commission post-swap.
    function uniswapV3SwapTo(
        uint256 receiver,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools
    ) external payable returns (uint256 returnAmount) {
        emit SwapOrderId((receiver & _ORDER_ID_MASK) >> 160);
        (address srcToken, address toToken) = _getUniswapV3TokenInfo(msg.value > 0, pools);
        return
            _uniswapV3SwapTo(
                msg.sender,
                receiver,
                srcToken,
                toToken,
                amount,
                minReturn,
                pools
            );
    }

    /// @notice If srcToken or toToken is ETH, the address needs to be 0xEeee. And for commission validation, ETH needs to be 0xEeee.
    function _uniswapV3SwapTo(
        address payer,
        uint256 receiver,
        address srcToken,
        address toToken,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools
    ) internal returns (uint256 returnAmount) {
        address receiverAddr = (receiver & _ADDRESS_MASK) == 0 ? msg.sender : _bytes32ToAddress(receiver);
        (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo) = _getCommissionAndTrimInfo();
        // add permit2
        _validateCommissionInfo(commissionInfo, srcToken, toToken, _MODE_LEGACY);

        returnAmount = _getBalanceOf(toToken, receiverAddr);

        _doUniswapV3Swap(
            payer,
            receiverAddr,
            amount,
            minReturn,
            toToken,
            pools,
            commissionInfo,
            trimInfo
        );

        // check minReturnAmount
        returnAmount = _getBalanceOf(toToken, receiverAddr) - returnAmount;
        require(
            returnAmount >= minReturn,
            "Min return not reached"
        );

        emit OrderRecord(
            srcToken,
            toToken,
            tx.origin,
            amount,
            returnAmount
        );
    }

    function _doUniswapV3Swap(
        address payer,
        address receiver,
        uint256 amount,
        uint256 minReturn,
        address toToken,
        uint256[] calldata pools,
        CommissionInfo memory commissionInfo,
        TrimInfo memory trimInfo
    ) private {
        (
            address middleReceiver,
            uint256 balanceBefore
        ) = _doCommissionFromToken(
                commissionInfo,
                payer,
                receiver,
                amount,
                trimInfo.hasTrim,
                toToken
            );

        _uniswapV3Swap(
            payer,
            payable(middleReceiver),
            amount,
            minReturn,
            pools
        );

        _doCommissionAndTrimToToken(
            commissionInfo,
            receiver,
            balanceBefore,
            toToken,
            trimInfo
        );
    }

    /// @notice Executes a smart swap directly to a specified receiver address.
    /// @param orderId Unique identifier for the swap order, facilitating tracking.
    /// @param receiver Address to receive the output tokens from the swap.
    /// @param baseRequest Contains essential parameters for the swap such as source and destination tokens, amounts, and deadline.
    /// @param batchesAmount Array indicating amounts for each batch in the swap, allowing for split operations.
    /// @param batches Detailed routing information for executing the swap across different paths or protocols.
    /// @return returnAmount The total amount of destination tokens received from the swap.
    /// @dev This function enables users to perform token swaps with complex routing directly to a specified address,
    /// optimizing for best returns and accommodating specific trading strategies.

    function smartSwapTo(
        uint256 orderId,
        address receiver,
        BaseRequest calldata baseRequest,
        uint256[] calldata batchesAmount,
        RouterPath[][] calldata batches,
        PMMLib.PMMSwapRequest[] calldata // extraData
    )
        external
        payable
        isExpired(baseRequest.deadLine)
        returns (uint256 returnAmount)
    {
        emit SwapOrderId(orderId);
        return
            _smartSwapTo(
                msg.sender,
                msg.sender,
                receiver,
                baseRequest,
                batchesAmount,
                batches
            );
    }

    /// @notice If fromToken or toToken is ETH, the address needs to be 0xEeee. And for commission validation, ETH needs to be 0xEeee.
    function _smartSwapTo(
        address payer,
        address refundTo,
        address receiver,
        BaseRequest memory baseRequest,
        uint256[] memory batchesAmount,
        RouterPath[][] memory batches
    ) internal returns (uint256 returnAmount) {
        receiver = receiver == address(0) ? msg.sender : receiver;
        (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo) = _getCommissionAndTrimInfo();
        
        uint256 mode = batches[0][0].fromToken & _TRANSFER_MODE_MASK;
        
        _validateCommissionInfo(commissionInfo, _bytes32ToAddress(baseRequest.fromToken), baseRequest.toToken, mode);

        returnAmount = _getBalanceOf(baseRequest.toToken, receiver);

        {
            (
                address middleReceiver,
                uint256 balanceBefore
            ) = _doCommissionFromToken(
                    commissionInfo,
                    payer,
                    receiver,
                    baseRequest.fromTokenAmount,
                    trimInfo.hasTrim,
                    baseRequest.toToken
                );

            _smartSwapInternal(
                baseRequest,
                batchesAmount,
                batches,
                payer,
                refundTo,
                middleReceiver
            );

            _doCommissionAndTrimToToken(
                commissionInfo,
                receiver,
                balanceBefore,
                baseRequest.toToken,
                trimInfo
            );
        }

        // check minReturnAmount
        returnAmount =
            _getBalanceOf(baseRequest.toToken, receiver) -
            returnAmount;
        require(
            returnAmount >= baseRequest.minReturnAmount,
            "Min return not reached"
        );

        emit OrderRecord(
            _bytes32ToAddress(baseRequest.fromToken),
            baseRequest.toToken,
            tx.origin,
            baseRequest.fromTokenAmount,
            returnAmount
        );
    }
    /// @notice Executes a token swap using the Unxswap protocol, sending the output directly to a specified receiver.
    ///         The srcToken can be 0xEeee or address(0) for temporary use, the address(0) usage will removed in the future.
    /// @param srcToken The source token to be swapped.
    /// @param amount The amount of the source token to be swapped.
    /// @param minReturn The minimum amount of destination tokens expected from the swap, ensuring the trade does not proceed under unfavorable conditions.
    /// @param receiver The address where the swapped tokens will be sent.
    /// @param pools An array of pool identifiers to specify the swap route, optimizing for best rates.
    /// @return returnAmount The total amount of destination tokens received from the swap.
    /// @dev This function facilitates direct swaps using Unxswap, allowing users to specify custom swap routes and ensuring that the output is sent to a predetermined address. It is designed for scenarios where the user wants to directly receive the tokens in their wallet or another contract.
    function unxswapTo(
        uint256 srcToken,
        uint256 amount,
        uint256 minReturn,
        address receiver,
        // solhint-disable-next-line no-unused-vars
        bytes32[] calldata pools
    ) public payable returns (uint256 returnAmount) {
        emit SwapOrderId((srcToken & _ORDER_ID_MASK) >> 160);

        // validate token info
        (address fromToken, address toToken) = _getUnxswapTokenInfo(msg.value > 0, pools);
        address srcTokenAddr = _bytes32ToAddress(srcToken);
        require(
            (srcTokenAddr == fromToken) || (srcTokenAddr == address(0) && fromToken == _ETH),
            "unxswap: token mismatch"
        );
        
        return
            _unxswapTo(
                fromToken,
                toToken,
                amount,
                minReturn,
                msg.sender,
                receiver,
                pools
            );
    }

    /// @notice If srcToken is ETH, srcToken needs to be 0xEeee for commission validation and _unxswapInternal.
    function _unxswapTo(
        address srcToken,
        address toToken,
        uint256 amount,
        uint256 minReturn,
        address payer,
        address receiver,
        // solhint-disable-next-line no-unused-vars
        bytes32[] calldata pools
    ) internal returns (uint256 returnAmount) {
        receiver = receiver == address(0) ? msg.sender : receiver;
        (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo) = _getCommissionAndTrimInfo();

        _validateCommissionInfo(commissionInfo, srcToken, toToken, _MODE_LEGACY);
        returnAmount = _getBalanceOf(toToken, receiver);

        _doUnxswap(payer, receiver, srcToken, toToken, amount, minReturn, pools, commissionInfo, trimInfo);

        // check minReturnAmount
        returnAmount = _getBalanceOf(toToken, receiver) - returnAmount;
        require(
            returnAmount >= minReturn,
            "Min return not reached"
        );

        emit OrderRecord(
            srcToken,
            toToken,
            tx.origin,
            amount,
            returnAmount
        );

        return returnAmount;
    }

    function _doUnxswap(
        address payer,
        address receiver,
        address srcToken,
        address toToken,
        uint256 amount,
        uint256 minReturn,
        bytes32[] calldata pools,
        CommissionInfo memory commissionInfo,
        TrimInfo memory trimInfo
    ) private {
        (
            address middleReceiver,
            uint256 balanceBefore
        ) = _doCommissionFromToken(
                commissionInfo,
                payer,
                receiver,
                amount,
                trimInfo.hasTrim,
                toToken
            );

        address _payer = payer;
        _unxswapInternal(
            IERC20(srcToken),
            amount,
            minReturn,
            pools,
            _payer,
            middleReceiver
        );

        _doCommissionAndTrimToToken(
            commissionInfo,
            receiver,
            balanceBefore,
            toToken,
            trimInfo
        );
    }

    /// @notice Executes a Uniswap V3 token swap to a specified receiver using structured base request parameters. For uniswapV3, if fromToken or toToken is ETH, the address needs to be 0xEeee.
    /// @param orderId Unique identifier for the swap order, facilitating tracking and reference.
    /// @param receiver The address that will receive the swapped tokens.
    /// @param baseRequest Struct containing essential swap parameters including source token, destination token, amount, minimum return, and deadline.
    /// @param pools An array of pool identifiers defining the Uniswap V3 swap route, with encoded swap direction and unwrap flags.
    /// @return returnAmount The total amount of destination tokens received from the swap.
    /// @dev This function validates token compatibility with the provided pool route and ensures proper swap execution.
    /// It supports both ETH and ERC20 token swaps, with automatic WETH wrapping/unwrapping as needed.
    /// The function verifies that fromToken matches the first pool and toToken matches the last pool in the route.
    function uniswapV3SwapToWithBaseRequest(
        uint256 orderId,
        address receiver,
        BaseRequest calldata baseRequest,
        uint256[] calldata pools
    )
        external
        payable
        isExpired(baseRequest.deadLine)
        returns (uint256 returnAmount)
    {
        emit SwapOrderId(orderId);

        (address srcToken, address toToken) = _getUniswapV3TokenInfo(msg.value > 0, pools);

        // validate fromToken and toToken from baseRequest
        require(
            _bytes32ToAddress(baseRequest.fromToken) == srcToken && baseRequest.toToken == toToken,
            "uniswapV3: token mismatch"
        );

        return
            _uniswapV3SwapTo(
                msg.sender,
                uint256(uint160(receiver)),
                srcToken,
                toToken,
                baseRequest.fromTokenAmount,
                baseRequest.minReturnAmount,
                pools
            );
    }

    /// @notice Executes a Unxswap token swap to a specified receiver using structured base request parameters. For unxswap, if fromToken or toToken is ETH, the address can be 0xEeee or address(0) for temporary use, the address(0) usage will removed in the future.
    /// @param orderId Unique identifier for the swap order, facilitating tracking and reference.
    /// @param receiver The address that will receive the swapped tokens.
    /// @param baseRequest Struct containing essential swap parameters including source token, destination token, amount, minimum return, and deadline.
    /// @param pools An array of pool identifiers defining the Unxswap route, with encoded swap direction and WETH unwrap flags.
    /// @return returnAmount The total amount of destination tokens received from the swap.
    /// @dev This function validates token compatibility with the provided pool route and ensures proper swap execution.
    /// It supports both ETH and ERC20 token swaps, with automatic WETH wrapping/unwrapping as needed.
    /// The function verifies that toToken matches the expected output token from the last pool in the route.
    function unxswapToWithBaseRequest(
        uint256 orderId,
        address receiver,
        BaseRequest calldata baseRequest,
        bytes32[] calldata pools
    )
        external
        payable
        isExpired(baseRequest.deadLine)
        returns (uint256 returnAmount)
    {
        emit SwapOrderId(orderId);

        (address fromToken, address toToken) = _getUnxswapTokenInfo(msg.value > 0, pools);

        // validate fromToken and toToken from baseRequest
        address fromTokenAddr = _bytes32ToAddress(baseRequest.fromToken);
        require((fromTokenAddr == fromToken) || (fromTokenAddr == address(0) && fromToken == _ETH), "unxswap: fromToken mismatch");
        require((baseRequest.toToken == toToken) || (baseRequest.toToken == address(0) && toToken == _ETH), "unxswap: toToken mismatch");

        return
            _unxswapTo(
                fromToken,
                toToken,
                baseRequest.fromTokenAmount,
                baseRequest.minReturnAmount,
                msg.sender,
                receiver,
                pools
            );
    }

    /// @notice For commission validation, ETH needs to be 0xEeee.
    function _swapWrap(
        uint256 orderId,
        address receiver,
        bool reversed,
        uint256 amount
    ) internal {
        emit SwapOrderId(orderId);

        require(amount > 0, "amount must be > 0");
        receiver = receiver == address(0) ? msg.sender : receiver;

        (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo) = _getCommissionAndTrimInfo();

        address srcToken = reversed ? _WETH : _ETH;
        address toToken = reversed ? _ETH : _WETH;

        _validateCommissionInfo(commissionInfo, srcToken, toToken, _MODE_LEGACY);

        (
            address middleReceiver,
            uint256 balanceBefore
        ) = _doCommissionFromToken(
                commissionInfo,
                msg.sender,
                receiver,
                amount,
                trimInfo.hasTrim,
                toToken
            );

        if (reversed) {
            IApproveProxy(_APPROVE_PROXY).claimTokens(
                _WETH,
                msg.sender,
                _WNATIVE_RELAY,
                amount
            );
            IWNativeRelayer(_WNATIVE_RELAY).withdraw(amount);
            if (middleReceiver != address(this)) {
                (bool success, ) = payable(middleReceiver).call{
                    value: address(this).balance
                }("");
                require(success, "transfer native token failed");
            }
        } else {
            if (!commissionInfo.isFromTokenCommission) {
                require(msg.value == amount, "value not equal amount");
            }
            IWETH(_WETH).deposit{value: amount}();
            if (middleReceiver != address(this)) {
                SafeERC20.safeTransfer(IERC20(_WETH), middleReceiver, amount);
            }
        }
        // emit return amount should be the amount after commission
        uint256 toTokenCommissionAndTrimAmount = _doCommissionAndTrimToToken(
            commissionInfo,
            receiver,
            balanceBefore,
            toToken,
            trimInfo
        );

        emit OrderRecord(
            srcToken,
            toToken,
            tx.origin,
            amount,
            amount - toTokenCommissionAndTrimAmount
        );
    }

    /// @notice Executes a simple swap between ETH and WETH using encoded parameters.
    /// @param orderId Unique identifier for the swap order, facilitating tracking and reference.
    /// @param rawdata Encoded data containing swap direction and amount information using bit masks.
    /// @dev This function supports bidirectional swaps between ETH and WETH with minimal gas overhead.
    /// The rawdata parameter encodes both the direction (reversed flag) and amount using bit operations.
    /// When reversed=false: ETH -> WETH, when reversed=true: WETH -> ETH.
    function swapWrap(uint256 orderId, uint256 rawdata) external payable {
        bool reversed;
        uint128 amount;
        assembly {
            reversed := and(rawdata, _REVERSE_MASK)
            amount := and(rawdata, SWAP_AMOUNT)
        }
        _swapWrap(orderId, msg.sender, reversed, amount);
    }

    /// @notice Executes a swap between ETH and WETH using structured base request parameters to a specified receiver.
    /// @param orderId Unique identifier for the swap order, facilitating tracking and reference.
    /// @param receiver The address that will receive the swapped tokens.
    /// @param baseRequest Struct containing essential swap parameters including source token, destination token, amount, minimum return, and deadline.
    /// @dev This function validates that the token pair is either ETH->WETH or WETH->ETH and executes the swap accordingly.
    /// It extracts the amount from the baseRequest and determines the swap direction based on the token addresses.
    function swapWrapToWithBaseRequest(
        uint256 orderId,
        address receiver,
        BaseRequest calldata baseRequest
    )
        external
        payable
        isExpired(baseRequest.deadLine)
    {
        bool reversed;
        address fromTokenAddr = _bytes32ToAddress(baseRequest.fromToken);
        if (fromTokenAddr == _ETH && baseRequest.toToken == _WETH) {
            reversed = false;
        } else if (fromTokenAddr == _WETH && baseRequest.toToken == _ETH) {
            reversed = true;
        } else {
            revert("SwapWrap: invalid token pair");
        }

        _swapWrap(orderId, receiver, reversed, baseRequest.fromTokenAmount);
    }

    function dagSwapByOrderId(
        uint256 orderId,
        BaseRequest calldata baseRequest,
        RouterPath[] calldata paths
    ) external payable  returns (uint256 returnAmount) {
        return dagSwapTo(orderId, msg.sender, baseRequest, paths);
    }

    /// @notice Executes a DAG swap to a specified receiver using structured base request parameters.
    /// @param orderId Unique identifier for the swap order, facilitating tracking and reference.
    /// @param receiver The address that will receive the swapped tokens.
    /// @param baseRequest Struct containing essential swap parameters including source token, destination token, amount, minimum return, and deadline.
    /// @param paths An array of RouterPath structs defining the DAG swap route.
    /// @return returnAmount The total amount of destination tokens received from the swap.
    /// @dev This function validates token compatibility with the provided pool route and ensures proper swap execution.
    function dagSwapTo(
        uint256 orderId,
        address receiver,
        BaseRequest calldata baseRequest,
        RouterPath[] calldata paths
    )
        public
        payable
        isExpired(baseRequest.deadLine)
        returns (uint256 returnAmount)
    {
        require(paths.length > 0, "paths must be > 0");
        emit SwapOrderId(orderId);

        receiver = receiver == address(0) ? msg.sender : receiver;

        (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo) = _getCommissionAndTrimInfo();
        
        uint256 mode = paths[0].fromToken & _TRANSFER_MODE_MASK;
        
        _validateCommissionInfo(commissionInfo, _bytes32ToAddress(baseRequest.fromToken), baseRequest.toToken, mode);

        returnAmount = _getBalanceOf(baseRequest.toToken, receiver);

        (
            address middleReceiver,
            uint256 balanceBefore
        ) = _doCommissionFromToken(
                commissionInfo,
                msg.sender,
                receiver,
                baseRequest.fromTokenAmount,
                trimInfo.hasTrim,
                baseRequest.toToken
            );

        _dagSwapInternal(
            baseRequest,
            paths,
            msg.sender,
            msg.sender,
            middleReceiver
        );

        _doCommissionAndTrimToToken(
            commissionInfo,
            receiver,
            balanceBefore,
            baseRequest.toToken,
            trimInfo
        );

        // check minReturnAmount
        returnAmount =
            _getBalanceOf(baseRequest.toToken, receiver) -
            returnAmount;
        require(
            returnAmount >= baseRequest.minReturnAmount,
            "Min return not reached"
        );

        emit OrderRecord(
            _bytes32ToAddress(baseRequest.fromToken),
            baseRequest.toToken,
            tx.origin,
            baseRequest.fromTokenAmount,
            returnAmount
        );
    }
}

// File: contracts/8/UnxswapRouter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IUni.sol";

import "./libraries/UniversalERC20.sol";
import "./libraries/CommonUtils.sol";

contract UnxswapRouter is CommonUtils {
    uint256 private constant _IS_TOKEN0_TAX =
        0x1000000000000000000000000000000000000000000000000000000000000000;
    uint256 private constant _IS_TOKEN1_TAX =
        0x2000000000000000000000000000000000000000000000000000000000000000;
    uint256 private constant _CLAIM_TOKENS_CALL_SELECTOR_32 =
        0x0a5ea46600000000000000000000000000000000000000000000000000000000;
    uint256 private constant _TRANSFER_DEPOSIT_SELECTOR =
        0xa9059cbbd0e30db0000000000000000000000000000000000000000000000000;
    uint256 private constant _SWAP_GETRESERVES_SELECTOR =
        0x022c0d9f0902f1ac000000000000000000000000000000000000000000000000;
    uint256 private constant _WITHDRAW_TRNASFER_SELECTOR =
        0x2e1a7d4da9059cbb000000000000000000000000000000000000000000000000;
    uint256 private constant _BALANCEOF_TOKEN0_SELECTOR =
        0x70a082310dfe1681000000000000000000000000000000000000000000000000;
    uint256 private constant _BALANCEOF_TOKEN1_SELECTOR =
        0x70a08231d21220a7000000000000000000000000000000000000000000000000;

    uint256 private constant _NUMERATOR_MASK =
        0x0000000000000000ffffffff0000000000000000000000000000000000000000;

    uint256 private constant _DENOMINATOR = 1_000_000_000;
    uint256 private constant _NUMERATOR_OFFSET = 160;

    //-------------------------------
    //------- Internal Functions ----
    //-------------------------------
    /// @notice Performs the internal logic for executing a swap using the Unxswap protocol.
    /// @param srcToken The token to be swapped.
    /// @param amount The amount of the source token to be swapped.
    /// @param minReturn The minimum amount of tokens that must be received for the swap to be valid, protecting against slippage.
    /// @param pools The array of pool identifiers that define the swap route.
    /// @param payer The address of the entity providing the source tokens for the swap.
    /// @param receiver The address that will receive the tokens after the swap.
    /// @return returnAmount The amount of tokens received from the swap.
    /// @dev This internal function encapsulates the core logic of the Unxswap token swap process. It is meant to be called by other external functions that set up the required parameters. The actual interaction with the Unxswap pools and the token transfer mechanics are implemented here.
    function _unxswapInternal(
        IERC20 srcToken,
        uint256 amount,
        uint256 minReturn,
        // solhint-disable-next-line no-unused-vars
        bytes32[] calldata pools,
        address payer,
        address receiver
    ) internal returns (uint256 returnAmount) {
        assembly {
            // solhint-disable-line no-inline-assembly

            function revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            function _getTokenAddr(emptyPtr, pair, selector) -> token {
                mstore(emptyPtr, selector)
                if iszero(
                    staticcall(
                        gas(),
                        pair,
                        add(0x04, emptyPtr),
                        0x04,
                        0x00,
                        0x20
                    )
                ) {
                    revertWithReason(
                        0x0000001067657420746f6b656e206661696c6564000000000000000000000000,
                        0x54
                    ) // "get token failed"
                }
                token := mload(0x00)
            }
            function _getBalanceOfToken0(emptyPtr, pair) -> token0, balance0 {
                mstore(emptyPtr, _BALANCEOF_TOKEN0_SELECTOR)
                if iszero(
                    staticcall(
                        gas(),
                        pair,
                        add(0x04, emptyPtr),
                        0x04,
                        0x00,
                        0x20
                    )
                ) {
                    revertWithReason(
                        0x00000012746f6b656e302063616c6c206661696c656400000000000000000000,
                        0x56
                    ) // "token0 call failed"
                }
                token0 := mload(0x00)
                mstore(add(0x04, emptyPtr), pair)
                if iszero(
                    staticcall(gas(), token0, emptyPtr, 0x24, 0x00, 0x20)
                ) {
                    revertWithReason(
                        0x0000001562616c616e63654f662063616c6c206661696c656400000000000000,
                        0x59
                    ) // "balanceOf call failed"
                }
                balance0 := mload(0x00)
            }
            function _getBalanceOfToken1(emptyPtr, pair) -> token1, balance1 {
                mstore(emptyPtr, _BALANCEOF_TOKEN1_SELECTOR)
                if iszero(
                    staticcall(
                        gas(),
                        pair,
                        add(0x04, emptyPtr),
                        0x04,
                        0x00,
                        0x20
                    )
                ) {
                    revertWithReason(
                        0x00000012746f6b656e312063616c6c206661696c656400000000000000000000,
                        0x56
                    ) // "token1 call failed"
                }
                token1 := mload(0x00)
                mstore(add(0x04, emptyPtr), pair)
                if iszero(
                    staticcall(gas(), token1, emptyPtr, 0x24, 0x00, 0x20)
                ) {
                    revertWithReason(
                        0x0000001562616c616e63654f662063616c6c206661696c656400000000000000,
                        0x59
                    ) // "balanceOf call failed"
                }
                balance1 := mload(0x00)
            }

            function swap(
                emptyPtr,
                swapAmount,
                pair,
                reversed,
                isToken0Tax,
                isToken1Tax,
                numerator,
                dst
            ) -> ret {
                mstore(emptyPtr, _SWAP_GETRESERVES_SELECTOR)
                if iszero(
                    staticcall(
                        gas(),
                        pair,
                        add(0x04, emptyPtr),
                        0x4,
                        0x00,
                        0x40
                    )
                ) {
                    // we only need the first 0x40 bytes, no need timestamp info
                    revertWithReason(
                        0x0000001472657365727665732063616c6c206661696c65640000000000000000,
                        0x58
                    ) // "reserves call failed"
                }
                let reserve0 := mload(0x00)
                let reserve1 := mload(0x20)

                switch reversed
                case 0 {
                    //swap token0 for token1
                    if isToken0Tax {
                        let token0, balance0 := _getBalanceOfToken0(
                            emptyPtr,
                            pair
                        )
                        swapAmount := sub(balance0, reserve0)
                    }
                }
                default {
                    //swap token1 for token0
                    if isToken1Tax {
                        let token1, balance1 := _getBalanceOfToken1(
                            emptyPtr,
                            pair
                        )
                        swapAmount := sub(balance1, reserve1)
                    }
                    let temp := reserve0
                    reserve0 := reserve1
                    reserve1 := temp
                }

                ret := mul(swapAmount, numerator)
                ret := div(
                    mul(ret, reserve1),
                    add(ret, mul(reserve0, _DENOMINATOR))
                )
                mstore(emptyPtr, _SWAP_GETRESERVES_SELECTOR)
                switch reversed
                case 0 {
                    mstore(add(emptyPtr, 0x04), 0)
                    mstore(add(emptyPtr, 0x24), ret)
                }
                default {
                    mstore(add(emptyPtr, 0x04), ret)
                    mstore(add(emptyPtr, 0x24), 0)
                }
                mstore(add(emptyPtr, 0x44), dst)
                mstore(add(emptyPtr, 0x64), 0x80)
                mstore(add(emptyPtr, 0x84), 0)
                if iszero(call(gas(), pair, 0, emptyPtr, 0xa4, 0, 0)) {
                    revertWithReason(
                        0x00000010737761702063616c6c206661696c6564000000000000000000000000,
                        0x54
                    ) // "swap call failed"
                }
            }

            let poolsOffset
            let poolsEndOffset
            {
                let len := pools.length
                poolsOffset := pools.offset //
                poolsEndOffset := add(poolsOffset, mul(len, 32))

                if eq(len, 0) {
                    revertWithReason(
                        0x000000b656d70747920706f6f6c73000000000000000000000000000000000000,
                        0x4e
                    ) // "empty pools"
                }
            }
            let emptyPtr := mload(0x40)
            let rawPair := calldataload(poolsOffset)
            switch eq(_ETH, srcToken)
            case 1 {
                // require callvalue() >= amount, lt: if x < y return 1，else return 0
                if eq(lt(callvalue(), amount), 1) {
                    revertWithReason(
                        0x00000011696e76616c6964206d73672e76616c75650000000000000000000000,
                        0x55
                    ) // "invalid msg.value"
                }

                mstore(emptyPtr, _TRANSFER_DEPOSIT_SELECTOR)
                if iszero(
                    call(gas(), _WETH, amount, add(emptyPtr, 0x04), 0x4, 0, 0)
                ) {
                    revertWithReason(
                        0x000000126465706f73697420455448206661696c656400000000000000000000,
                        0x56
                    ) // "deposit ETH failed"
                }
                mstore(add(0x04, emptyPtr), and(rawPair, _ADDRESS_MASK))
                mstore(add(0x24, emptyPtr), amount)
                if iszero(call(gas(), _WETH, 0, emptyPtr, 0x44, 0, 0x20)) {
                    revertWithReason(
                        0x000000147472616e736665722057455448206661696c65640000000000000000,
                        0x58
                    ) // "transfer WETH failed"
                }
            }
            default {
                if callvalue() {
                    revertWithReason(
                        0x00000011696e76616c6964206d73672e76616c75650000000000000000000000,
                        0x55
                    ) // "invalid msg.value"
                }

                mstore(emptyPtr, _CLAIM_TOKENS_CALL_SELECTOR_32)
                mstore(add(emptyPtr, 0x4), srcToken)
                mstore(add(emptyPtr, 0x24), payer)
                mstore(add(emptyPtr, 0x44), and(rawPair, _ADDRESS_MASK))
                mstore(add(emptyPtr, 0x64), amount)
                if iszero(
                    call(gas(), _APPROVE_PROXY, 0, emptyPtr, 0x84, 0, 0)
                ) {
                    revertWithReason(
                        0x00000012636c61696d20746f6b656e206661696c656400000000000000000000,
                        0x56
                    ) // "claim token failed"
                }
            }

            returnAmount := amount

            for {
                let i := add(poolsOffset, 0x20)
            } lt(i, poolsEndOffset) {
                i := add(i, 0x20)
            } {
                let nextRawPair := calldataload(i)

                returnAmount := swap(
                    emptyPtr,
                    returnAmount,
                    and(rawPair, _ADDRESS_MASK),
                    and(rawPair, _REVERSE_MASK),
                    and(rawPair, _IS_TOKEN0_TAX),
                    and(rawPair, _IS_TOKEN1_TAX),
                    shr(_NUMERATOR_OFFSET, and(rawPair, _NUMERATOR_MASK)),
                    and(nextRawPair, _ADDRESS_MASK)
                )

                rawPair := nextRawPair
            }
            let toToken
            switch and(rawPair, _WETH_MASK)
            case 0 {
                let beforeAmount
                switch and(rawPair, _REVERSE_MASK)
                case 0 {
                    if and(rawPair, _IS_TOKEN1_TAX) {
                        mstore(emptyPtr, _BALANCEOF_TOKEN1_SELECTOR)
                        if iszero(
                            staticcall(
                                gas(),
                                and(rawPair, _ADDRESS_MASK),
                                add(0x04, emptyPtr),
                                0x04,
                                0x00,
                                0x20
                            )
                        ) {
                            revertWithReason(
                                0x00000012746f6b656e312063616c6c206661696c656400000000000000000000,
                                0x56
                            ) // "token1 call failed"
                        }
                        toToken := mload(0)
                        mstore(add(0x04, emptyPtr), receiver)
                        if iszero(
                            staticcall(
                                gas(),
                                toToken,
                                emptyPtr,
                                0x24,
                                0x00,
                                0x20
                            )
                        ) {
                            revertWithReason(
                                0x00000015746f6b656e312062616c616e6365206661696c656400000000000000,
                                0x59
                            ) // "token1 balance failed"
                        }
                        beforeAmount := mload(0)
                    }
                }
                default {
                    if and(rawPair, _IS_TOKEN0_TAX) {
                        mstore(emptyPtr, _BALANCEOF_TOKEN0_SELECTOR)
                        if iszero(
                            staticcall(
                                gas(),
                                and(rawPair, _ADDRESS_MASK),
                                add(0x04, emptyPtr),
                                0x04,
                                0x00,
                                0x20
                            )
                        ) {
                            revertWithReason(
                                0x00000012746f6b656e302063616c6c206661696c656400000000000000000000,
                                0x56
                            ) // "token0 call failed"
                        }
                        toToken := mload(0)
                        mstore(add(0x04, emptyPtr), receiver)
                        if iszero(
                            staticcall(
                                gas(),
                                toToken,
                                emptyPtr,
                                0x24,
                                0x00,
                                0x20
                            )
                        ) {
                            revertWithReason(
                                0x00000015746f6b656e302062616c616e6365206661696c656400000000000000,
                                0x56
                            ) // "token0 balance failed"
                        }
                        beforeAmount := mload(0)
                    }
                }
                returnAmount := swap(
                    emptyPtr,
                    returnAmount,
                    and(rawPair, _ADDRESS_MASK),
                    and(rawPair, _REVERSE_MASK),
                    and(rawPair, _IS_TOKEN0_TAX),
                    and(rawPair, _IS_TOKEN1_TAX),
                    shr(_NUMERATOR_OFFSET, and(rawPair, _NUMERATOR_MASK)),
                    receiver
                )
                switch lt(0x0, toToken)
                case 1 {
                    mstore(emptyPtr, _BALANCEOF_TOKEN0_SELECTOR)
                    mstore(add(0x04, emptyPtr), receiver)
                    if iszero(
                        staticcall(gas(), toToken, emptyPtr, 0x24, 0x00, 0x20)
                    ) {
                        revertWithReason(
                            0x000000146765742062616c616e63654f66206661696c65640000000000000000,
                            0x58
                        ) // "get balanceOf failed"
                    }
                    returnAmount := sub(mload(0), beforeAmount)
                }
                default {
                    // set token0 addr for the non-safemoon token
                    switch and(rawPair, _REVERSE_MASK)
                    case 0 {
                        // get token1
                        toToken := _getTokenAddr(
                            emptyPtr,
                            and(rawPair, _ADDRESS_MASK),
                            _BALANCEOF_TOKEN1_SELECTOR
                        )
                    }
                    default {
                        // get token0
                        toToken := _getTokenAddr(
                            emptyPtr,
                            and(rawPair, _ADDRESS_MASK),
                            _BALANCEOF_TOKEN0_SELECTOR
                        )
                    }
                }
            }
            default {
                toToken := _ETH
                returnAmount := swap(
                    emptyPtr,
                    returnAmount,
                    and(rawPair, _ADDRESS_MASK),
                    and(rawPair, _REVERSE_MASK),
                    and(rawPair, _IS_TOKEN0_TAX),
                    and(rawPair, _IS_TOKEN1_TAX),
                    shr(_NUMERATOR_OFFSET, and(rawPair, _NUMERATOR_MASK)),
                    address()
                )

                mstore(emptyPtr, _WITHDRAW_TRNASFER_SELECTOR)
                mstore(add(emptyPtr, 0x08), _WNATIVE_RELAY)
                mstore(add(emptyPtr, 0x28), returnAmount)
                if iszero(
                    call(gas(), _WETH, 0, add(0x04, emptyPtr), 0x44, 0, 0x20)
                ) {
                    revertWithReason(
                        0x000000147472616e736665722057455448206661696c65640000000000000000,
                        0x58
                    ) // "transfer WETH failed"
                }
                mstore(add(emptyPtr, 0x04), returnAmount)
                if iszero(
                    call(gas(), _WNATIVE_RELAY, 0, emptyPtr, 0x24, 0, 0x20)
                ) {
                    revertWithReason(
                        0x00000013776974686472617720455448206661696c6564000000000000000000,
                        0x57
                    ) // "withdraw ETH failed"
                }
                if iszero(call(gas(), receiver, returnAmount, 0, 0, 0, 0)) {
                    revertWithReason(
                        0x000000137472616e7366657220455448206661696c6564000000000000000000,
                        0x57
                    ) // "transfer ETH failed"
                }
            }

        }
    }
}


// File: contracts/8/UnxswapV3Router.sol
/// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniV3.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IWNativeRelayer.sol";

import "./libraries/Address.sol";
import "./libraries/CommonUtils.sol";
import "./libraries/RouterErrors.sol";
import "./libraries/SafeCast.sol";

contract UnxswapV3Router is IUniswapV3SwapCallback, CommonUtils {
    using Address for address payable;

    bytes32 private constant _POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54; // Pool init code hash
    bytes32 private constant _FF_FACTORY = 0xff1F98431c8aD98523631AE4a59f267346ea31F9840000000000000000000000; // Factory address
    // concatenation of token0(), token1() fee(), transfer() and claimTokens() selectors
    bytes32 private constant _SELECTORS =
        0x0dfe1681d21220a7ddca3f43a9059cbb0a5ea466000000000000000000000000;
    // concatenation of withdraw(uint),transfer()
    bytes32 private constant _SELECTORS2 =
        0x2e1a7d4da9059cbb000000000000000000000000000000000000000000000000;
    bytes32 private constant _SELECTORS3 =
        0xa9059cbb70a08231000000000000000000000000000000000000000000000000;
    uint160 private constant _MIN_SQRT_RATIO = 4_295_128_739 + 1;
    uint160 private constant _MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    bytes32 private constant _SWAP_SELECTOR =
        0x128acb0800000000000000000000000000000000000000000000000000000000; // Swap function selector
    uint256 private constant _INT256_MAX =
        0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff; // Maximum int256
    uint256 private constant _INT256_MIN =
        0x8000000000000000000000000000000000000000000000000000000000000000; // Minimum int256

    /// @notice Conducts a swap using the Uniswap V3 protocol internally within the contract.
    /// @param payer The address of the account providing the tokens for the swap.
    /// @param receiver The address that will receive the tokens after the swap.
    /// @param amount The amount of the source token to be swapped.
    /// @param minReturn The minimum amount of tokens that must be received for the swap to be valid, safeguarding against excessive slippage.
    /// @param pools An array of pool identifiers defining the swap route within Uniswap V3.
    /// @return returnAmount The amount of tokens received from the swap.
    /// @dev This internal function encapsulates the core logic for executing swaps on Uniswap V3. It is intended to be used by other functions in the contract that prepare and pass the necessary parameters. The function handles the swapping process, ensuring that the minimum return is met and managing the transfer of tokens.
    function _uniswapV3Swap(
        address payer,
        address payable receiver,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools
    ) internal returns (uint256 returnAmount) {
        assembly {
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            function _makeSwap(_receiver, _payer, _refundTo, _pool, _amount)
                -> _returnAmount
            {
                if lt(_INT256_MAX, _amount) {
                    mstore(
                        0,
                        0xb3f79fd000000000000000000000000000000000000000000000000000000000
                    ) //SafeCastToInt256Failed()
                    revert(0, 4)
                }
                let freePtr := mload(0x40)
                let zeroForOne := eq(and(_pool, _ONE_FOR_ZERO_MASK), 0)

                let poolAddr := and(_pool, _ADDRESS_MASK)
                switch zeroForOne
                case 1 {
                    mstore(freePtr, _SWAP_SELECTOR)
                    let paramPtr := add(freePtr, 4)
                    mstore(paramPtr, _receiver)
                    mstore(add(paramPtr, 0x20), true)
                    mstore(add(paramPtr, 0x40), _amount)
                    mstore(add(paramPtr, 0x60), _MIN_SQRT_RATIO)
                    mstore(add(paramPtr, 0x80), 0xa0)
                    mstore(add(paramPtr, 0xa0), 64)
                    mstore(add(paramPtr, 0xc0), _payer)
                    mstore(add(paramPtr, 0xe0), _refundTo)
                    let success := call(
                        gas(),
                        poolAddr,
                        0,
                        freePtr,
                        0x104,
                        0,
                        0
                    )
                    if iszero(success) {
                        revert(0, 32)
                    }
                    returndatacopy(0, 32, 32) // only copy _amount1   MEM[0:] <= RETURNDATA[32:32+32]
                }
                default {
                    mstore(freePtr, _SWAP_SELECTOR)
                    let paramPtr := add(freePtr, 4)
                    mstore(paramPtr, _receiver)
                    mstore(add(paramPtr, 0x20), false)
                    mstore(add(paramPtr, 0x40), _amount)
                    mstore(add(paramPtr, 0x60), _MAX_SQRT_RATIO)
                    mstore(add(paramPtr, 0x80), 0xa0)
                    mstore(add(paramPtr, 0xa0), 64)
                    mstore(add(paramPtr, 0xc0), _payer)
                    mstore(add(paramPtr, 0xe0), _refundTo)
                    let success := call(
                        gas(),
                        poolAddr,
                        0,
                        freePtr,
                        0x104,
                        0,
                        0
                    )
                    if iszero(success) {
                        revert(0, 32)
                    }
                    returndatacopy(0, 0, 32) // only copy _amount0   MEM[0:] <= RETURNDATA[0:0+32]
                }
                _returnAmount := mload(0)
                if lt(_returnAmount, _INT256_MIN) {
                    mstore(
                        0,
                        0x88c8ee9c00000000000000000000000000000000000000000000000000000000
                    ) //SafeCastToUint256Failed()
                    revert(0, 4)
                }
                _returnAmount := add(1, not(_returnAmount)) // -a = ~a + 1
            }
            function _wrapWeth(_amount) {
                // require callvalue() >= amount, lt: if x < y return 1，else return 0
                if eq(lt(callvalue(), _amount), 1) {
                    mstore(
                        0,
                        0x1841b4e100000000000000000000000000000000000000000000000000000000
                    ) // InvalidMsgValue()
                    revert(0, 4)
                }

                let success := call(gas(), _WETH, _amount, 0, 0, 0, 0) //进入fallback逻辑
                if iszero(success) {
                    _revertWithReason(
                        0x0000001357455448206465706f736974206661696c6564000000000000000000,
                        87
                    ) //WETH deposit failed
                }
            }
            function _unWrapWeth(_receiver, _amount) {
                let freePtr := mload(0x40)
                let transferPtr := add(freePtr, 4)

                mstore(freePtr, _SELECTORS2) // withdraw amountWith to amount
                // transfer
                mstore(add(transferPtr, 4), _WNATIVE_RELAY)
                mstore(add(transferPtr, 36), _amount)
                let success := call(gas(), _WETH, 0, transferPtr, 68, 0, 0)
                if iszero(success) {
                    _revertWithReason(
                        0x000000147472616e736665722077657468206661696c65640000000000000000,
                        88
                    ) // transfer weth failed
                }
                // withdraw
                mstore(add(freePtr, 4), _amount)
                success := call(gas(), _WNATIVE_RELAY, 0, freePtr, 36, 0, 0)
                if iszero(success) {
                    _revertWithReason(
                        0x0000001477697468647261772077657468206661696c65640000000000000000,
                        88
                    ) // withdraw weth failed
                }
                // msg.value transfer
                success := call(gas(), _receiver, _amount, 0, 0, 0, 0)
                if iszero(success) {
                    _revertWithReason(
                        0x0000001173656e64206574686572206661696c65640000000000000000000000,
                        85
                    ) // send ether failed
                }
            }
            function _token0(_pool) -> token0 {
                let freePtr := mload(0x40)
                mstore(freePtr, _SELECTORS)
                let success := staticcall(gas(), _pool, freePtr, 0x4, 0, 0)
                if iszero(success) {
                    _revertWithReason(
                        0x0000001167657420746f6b656e30206661696c65640000000000000000000000,
                        85
                    ) // get token0 failed
                }
                returndatacopy(0, 0, 32)
                token0 := mload(0)
            }
            function _token1(_pool) -> token1 {
                let freePtr := mload(0x40)
                mstore(freePtr, _SELECTORS)
                let success := staticcall(
                    gas(),
                    _pool,
                    add(freePtr, 4),
                    0x4,
                    0,
                    0
                )
                if iszero(success) {
                    _revertWithReason(
                        0x0000001167657420746f6b656e31206661696c65640000000000000000000000,
                        84
                    ) // get token1 failed
                }
                returndatacopy(0, 0, 32)
                token1 := mload(0)
            }

            let firstPoolStart
            let lastPoolStart

            {
                let len := pools.length
                firstPoolStart := pools.offset //
                lastPoolStart := sub(add(firstPoolStart, mul(len, 32)), 32)

                if eq(len, 0) {
                    mstore(
                        0,
                        0x67e7c0f600000000000000000000000000000000000000000000000000000000
                    ) // EmptyPools()
                    revert(0, 4)
                }
            }
            let refundTo := payer
            {
                let wrapWeth := gt(callvalue(), 0)
                if wrapWeth {
                    _wrapWeth(amount)
                    payer := address()
                }
            }

            mstore(96, amount) // 96 is not override by _makeSwap, since it only use freePtr memory, and it is not override by unWrapWeth ethier
            for {
                let i := firstPoolStart
            } lt(i, lastPoolStart) {
                i := add(i, 32)
            } {
                amount := _makeSwap(
                    address(),
                    payer,
                    refundTo,
                    calldataload(i),
                    amount
                )
                payer := address()
            }
            {
                let unwrapWeth := gt(
                    and(calldataload(lastPoolStart), _WETH_UNWRAP_MASK),
                    0
                ) // pools[lastIndex] & _WETH_UNWRAP_MASK > 0

                // last one or only one
                switch unwrapWeth
                case 1 {
                    returnAmount := _makeSwap(
                        address(),
                        payer,
                        refundTo,
                        calldataload(lastPoolStart),
                        amount
                    )
                    _unWrapWeth(receiver, returnAmount)
                }
                case 0 {
                    returnAmount := _makeSwap(
                        receiver,
                        payer,
                        refundTo,
                        calldataload(lastPoolStart),
                        amount
                    )
                }
            }

        }
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /*data*/
    ) external override {
        assembly {
            // solhint-disable-line no-inline-assembly
            function reRevert() {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            function getBalanceAndTransfer(emptyPtr, token) {
                mstore(emptyPtr, _SELECTORS3)
                mstore(add(8, emptyPtr), address())
                if iszero(
                    staticcall(gas(), token, add(4, emptyPtr), 36, 0, 32)
                ) {
                    reRevert()
                }
                let amount := mload(0)
                if gt(amount, 0) {
                    let refundTo := calldataload(164)
                    mstore(add(4, emptyPtr), refundTo)
                    mstore(add(36, emptyPtr), amount)
                    validateERC20Transfer(
                        call(gas(), token, 0, emptyPtr, 0x44, 0, 0x20)
                    )
                }
            }

            function validateERC20Transfer(status) {
                if iszero(status) {
                    reRevert()
                }
                let success := or(
                    iszero(returndatasize()), // empty return data
                    and(gt(returndatasize(), 31), eq(mload(0), 1)) // true in return data
                )
                if iszero(success) {
                    mstore(
                        0,
                        0xf27f64e400000000000000000000000000000000000000000000000000000000
                    ) // ERC20TransferFailed()
                    revert(0, 4)
                }
            }

            let emptyPtr := mload(0x40)
            let resultPtr := add(emptyPtr, 21) // 0x15 = _FF_FACTORY size

            mstore(emptyPtr, _SELECTORS)
            // token0
            if iszero(staticcall(gas(), caller(), emptyPtr, 4, 0, 32)) {
                reRevert()
            }
            //token1
            if iszero(
                staticcall(gas(), caller(), add(emptyPtr, 4), 4, 32, 32)
            ) {
                reRevert()
            }
            // fee
            if iszero(
                staticcall(gas(), caller(), add(emptyPtr, 8), 4, 64, 32)
            ) {
                reRevert()
            }

            let token
            let amount
            switch sgt(amount0Delta, 0)
            case 1 {
                token := mload(0)
                amount := amount0Delta
            }
            default {
                token := mload(32)
                amount := amount1Delta
            }
            // let salt := keccak256(0, 96)
            mstore(emptyPtr, _FF_FACTORY)
            mstore(resultPtr, keccak256(0, 96)) // Compute the inner hash in-place
            mstore(add(resultPtr, 32), _POOL_INIT_CODE_HASH)
            let pool := and(keccak256(emptyPtr, 85), _ADDRESS_MASK)
            if iszero(eq(pool, caller())) {
                // if xor(pool, caller()) {
                mstore(
                    0,
                    0xb2c0272200000000000000000000000000000000000000000000000000000000
                ) // BadPool()
                revert(0, 4)
            }

            let payer := calldataload(132) // 4+32+32+32+32 = 132
            mstore(emptyPtr, _SELECTORS)
            switch eq(payer, address())
            case 1 {
                // token.safeTransfer(msg.sender,amount)
                mstore(add(emptyPtr, 0x10), caller())
                mstore(add(emptyPtr, 0x30), amount)
                validateERC20Transfer(
                    call(gas(), token, 0, add(emptyPtr, 0x0c), 0x44, 0, 0x20)
                )
                getBalanceAndTransfer(emptyPtr, token)
            }
            default {
                // approveProxy.claimTokens(token, payer, msg.sender, amount);
                mstore(add(emptyPtr, 0x14), token)
                mstore(add(emptyPtr, 0x34), payer)
                mstore(add(emptyPtr, 0x54), caller())
                mstore(add(emptyPtr, 0x74), amount)
                validateERC20Transfer(
                    call(
                        gas(),
                        _APPROVE_PROXY,
                        0,
                        add(emptyPtr, 0x10),
                        0x84,
                        0,
                        0x20
                    )
                )
            }
        }
    }
}


// File: contracts/8/interfaces/IWETH.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

interface IWETH {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address src,
        address dst,
        uint256 wad
    ) external returns (bool);

    function deposit() external payable;

    function withdraw(uint256 wad) external;
}


// File: contracts/8/interfaces/IApproveProxy.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IApproveProxy {
    function isAllowedProxy(address _proxy) external view returns (bool);

    function claimTokens(
        address token,
        address who,
        address dest,
        uint256 amount
    ) external;

    function tokenApprove() external view returns (address);
    function addProxy(address) external;
}


// File: contracts/8/interfaces/IWNativeRelayer.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

interface IWNativeRelayer {
    function withdraw(uint256 _amount) external;
}


// File: contracts/8/libraries/PMMLib.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library PMMLib {

  // ============ Struct ============
  struct PMMSwapRequest {
      uint256 pathIndex;
      address payer;
      address fromToken;
      address toToken;
      uint256 fromTokenAmountMax;
      uint256 toTokenAmountMax;
      uint256 salt;
      uint256 deadLine;
      bool isPushOrder;
      bytes extension;
      // address marketMaker;
      // uint256 subIndex;
      // bytes signature;
      // uint256 source;  1byte type + 1byte bool（reverse） + 0...0 + 20 bytes address
  }

  struct PMMBaseRequest {
    uint256 fromTokenAmount;
    uint256 minReturnAmount;
    uint256 deadLine;
    bool fromNative;
    bool toNative;
  }

  enum PMM_ERROR {
      NO_ERROR,
      INVALID_OPERATOR,
      QUOTE_EXPIRED,
      ORDER_CANCELLED_OR_FINALIZED,
      REMAINING_AMOUNT_NOT_ENOUGH,
      INVALID_AMOUNT_REQUEST,
      FROM_TOKEN_PAYER_ERROR,
      TO_TOKEN_PAYER_ERROR,
      WRONG_FROM_TOKEN
  }

  event PMMSwap(
    uint256 pathIndex,
    uint256 subIndex,
    uint256 errorCode
  );

  error PMMErrorCode(uint256 errorCode);

}

// File: contracts/8/libraries/CommissionLib.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./CommonUtils.sol";
import "../interfaces/AbstractCommissionLib.sol";
/// @title Base contract with common permit handling logics

abstract contract CommissionLib is AbstractCommissionLib, CommonUtils {
    uint256 internal constant _COMMISSION_RATE_MASK =
        0x000000000000ffffffffffff0000000000000000000000000000000000000000;
    uint256 internal constant _COMMISSION_FLAG_MASK =
        0xffffffffffff0000000000000000000000000000000000000000000000000000;
    uint256 internal constant FROM_TOKEN_COMMISSION =
        0x3ca20afc2aaa0000000000000000000000000000000000000000000000000000;
    uint256 internal constant TO_TOKEN_COMMISSION =
        0x3ca20afc2bbb0000000000000000000000000000000000000000000000000000;
    uint256 internal constant FROM_TOKEN_COMMISSION_DUAL =
        0x22220afc2aaa0000000000000000000000000000000000000000000000000000;
    uint256 internal constant TO_TOKEN_COMMISSION_DUAL =
        0x22220afc2bbb0000000000000000000000000000000000000000000000000000;
    uint256 internal constant FROM_TOKEN_COMMISSION_MULTIPLE =
        0x88880afc2aaa0000000000000000000000000000000000000000000000000000;
    uint256 internal constant TO_TOKEN_COMMISSION_MULTIPLE =
        0x88880afc2bbb0000000000000000000000000000000000000000000000000000;
    uint256 internal constant _COMMISSION_LENGTH_MASK =
        0x00ff000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant _TO_B_COMMISSION_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;


    uint256 internal constant _TRIM_FLAG_MASK =
        0xffffffffffff0000000000000000000000000000000000000000000000000000;
    uint256 internal constant _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK =
        0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
    uint256 internal constant _TRIM_RATE_MASK =
        0x000000000000ffffffffffff0000000000000000000000000000000000000000;
    uint256 internal constant _TO_B_TRIM_MASK =
        0x0000000000008000000000000000000000000000000000000000000000000000;
    uint256 internal constant TRIM_FLAG =
        0x7777777711110000000000000000000000000000000000000000000000000000;
    uint256 internal constant TRIM_DUAL_FLAG =
        0x7777777722220000000000000000000000000000000000000000000000000000;

    event CommissionAndTrimInfo(
        uint256 toBCommission, // 0 for no commission, 1 for no-toB commission, 2 for toB commission
        uint256 toBTrim, // 0 for no trim, 1 for no-toB trim, 2 for toB trim
        uint256 trimRate,
        uint256 chargeRate
    );

    // @notice CommissionFromTokenRecord is emitted in assembly, commentted out for contract size saving
    // event CommissionFromTokenRecord(
    //     address fromTokenAddress,
    //     uint256 commissionAmount,
    //     address referrerAddress,
    //     uint256 commissionRate
    // );

    // @notice CommissionToTokenRecord is emitted in assembly, commentted out for contract size saving
    // event CommissionToTokenRecord(
    //     address toTokenAddress,
    //     uint256 commissionAmount,
    //     address referrerAddress,
    //     uint256 commissionRate
    // );

    // @notice PositiveSlippageTrimRecord is emitted in assembly, commentted out for contract size saving
    // event PositiveSlippageTrimRecord(
    //     address toTokenAddress,
    //     uint256 trimAmount,
    //     address trimAddress
    // );

    // @notice PositiveSlippageChargeRecord is emitted in assembly, commentted out for contract size saving
    // event PositiveSlippageChargeRecord(
    //     address toTokenAddress,
    //     uint256 chargeAmount,
    //     address chargeAddress
    // );

    // set default value can change when need.
    uint256 internal constant MIN_COMMISSION_MULTIPLE_NUM = 3; // min referrer num for multiple commission
    uint256 internal constant MAX_COMMISSION_MULTIPLE_NUM = 8; // max referrer num for multiple commission
    uint256 internal constant commissionRateLimit = 30000000;
    uint256 internal constant DENOMINATOR = 10 ** 9;
    uint256 internal constant NO_TO_B_MODE = 1; // value for no-toB commission and no-toB trim when related calldata exists
    uint256 internal constant TO_B_MODE = 2; // value for toB commission and toB trim when related calldata exists
    uint256 internal constant WAD = 1 ether;
    uint256 internal constant TRIM_RATE_LIMIT = 100;
    uint256 internal constant TRIM_DENOMINATOR = 1000;

    function _getCommissionAndTrimInfo()
        internal
        override
        returns (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo)
    {
        assembly ("memory-safe") {
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }

            let commissionData := calldataload(sub(calldatasize(), 0x20))
            let flag := and(commissionData, _COMMISSION_FLAG_MASK)
            let referrerNum := 0
            if or(
                eq(flag, FROM_TOKEN_COMMISSION),
                eq(flag, TO_TOKEN_COMMISSION)
            ) {
                referrerNum := 1
            }
            if or(
                eq(flag, FROM_TOKEN_COMMISSION_DUAL),
                eq(flag, TO_TOKEN_COMMISSION_DUAL)
            ) {
                referrerNum := 2
            }
            if or(
                eq(flag, FROM_TOKEN_COMMISSION_MULTIPLE),
                eq(flag, TO_TOKEN_COMMISSION_MULTIPLE)
            ) {
                referrerNum := 3 // default referrer num to load real encoded referrer num
            }
            mstore(
                commissionInfo,
                or(
                    or(
                        eq(flag, FROM_TOKEN_COMMISSION),
                        eq(flag, FROM_TOKEN_COMMISSION_DUAL)
                    ),
                    eq(flag, FROM_TOKEN_COMMISSION_MULTIPLE)
                )
            ) // isFromTokenCommission
            mstore(
                add(0x20, commissionInfo),
                or(
                    or(
                        eq(flag, TO_TOKEN_COMMISSION),
                        eq(flag, TO_TOKEN_COMMISSION_DUAL)
                    ),
                    eq(flag, TO_TOKEN_COMMISSION_MULTIPLE)
                )
            ) // isToTokenCommission
            switch gt(referrerNum, 0)
            case 1 {
                mstore(
                    add(0xa0, commissionInfo),
                    shr(160, and(commissionData, _COMMISSION_RATE_MASK))
                ) // 1st commissionRate
                mstore(
                    add(0xc0, commissionInfo),
                    and(commissionData, _ADDRESS_MASK)
                ) // 1st referrerAddress
                commissionData := calldataload(sub(calldatasize(), 0x40))
                let toBCommission := NO_TO_B_MODE // default toBCommission is 1 for no-toB commission when commissionData exists
                if gt(and(commissionData, _TO_B_COMMISSION_MASK), 0) {
                    toBCommission := TO_B_MODE // toB commission value when commissionData exists
                }
                mstore(
                    add(0x60, commissionInfo),
                    toBCommission //toBCommission
                )
                mstore(
                    add(0x40, commissionInfo),
                    and(commissionData, _ADDRESS_MASK) //token
                )
                // For multiple commission mode, load the encoded commission length and validate
                if gt(referrerNum, 2) {
                    referrerNum := shr(240, and(commissionData, _COMMISSION_LENGTH_MASK))
                    // require(referrerNum >= MIN_COMMISSION_MULTIPLE_NUM && referrerNum <= MAX_COMMISSION_MULTIPLE_NUM, "invalid referrer num")
                    if or(lt(referrerNum, MIN_COMMISSION_MULTIPLE_NUM), gt(referrerNum, MAX_COMMISSION_MULTIPLE_NUM)) {
                        _revertWithReason(
                            0x00000014696e76616c6964207265666572726572206e756d0000000000000000,
                            0x58
                        ) // "invalid referrer num"
                    }
                }
                mstore(add(0x80, commissionInfo), referrerNum) //commissionLength
            }
            default {
                let eraseNum := add(mul(MAX_COMMISSION_MULTIPLE_NUM, 2), 3) // 2 * MAX_COMMISSION_MULTIPLE_NUM + 3: token, toBCommission, commissionLength and all commission pairs
                for { let i := 0 } lt(i, eraseNum) { i := add(i, 1) } {
                    mstore(add(add(commissionInfo, 0x40), mul(i, 0x20)), 0) // erase commissionInfo.token ~ all commission pairs
                }
            }
            if gt(referrerNum, 1) {
                for { let i := 1 } lt(i, MAX_COMMISSION_MULTIPLE_NUM) { i := add(i, 1) } {
                    switch lt(i, referrerNum) // if i < referrerNum, the i-th commission pair is valid
                    case 1 {
                        commissionData := calldataload(sub(calldatasize(), add(0x40, mul(i, 0x20))))
                        let flag2 := and(commissionData, _COMMISSION_FLAG_MASK)
                        if iszero(eq(flag, flag2)) {
                            _revertWithReason(
                                0x00000017696e76616c696420636f6d6d697373696f6e20666c61670000000000,
                                0x5b
                            ) // "invalid commission flag"
                        }
                        mstore(
                            add(add(0xa0, commissionInfo), mul(i, 0x40)), // 0xa0: commissionRate0, 0xa0 + 0x40 * i: i-th commissionRate
                            shr(160, and(commissionData, _COMMISSION_RATE_MASK))
                        ) //i-th commissionRate
                        mstore(
                            add(add(0xc0, commissionInfo), mul(i, 0x40)), // 0xc0: referrerAddress0, 0xc0 + 0x40 * i: i-th referrerAddress
                            and(commissionData, _ADDRESS_MASK)
                        ) //i-th referrerAddress
                    }
                    default { // if i >= referrerNum, the i-th commission pair is invalid, and erase it
                        mstore(add(add(0xa0, commissionInfo), mul(i, 0x40)), 0) // erase i-th commissionRate
                        mstore(add(add(0xc0, commissionInfo), mul(i, 0x40)), 0) // erase i-th referrerAddress
                    }
                }
            }
            // calculate offset based on referrerNum
            let offset := 0
            if gt(referrerNum, 0) {
                offset := mul(add(referrerNum, 1), 0x20)
            }
            // get first bytes32 of trim data
            let trimData := calldataload(sub(calldatasize(), add(offset, 0x20)))
            flag := and(trimData, _TRIM_FLAG_MASK)
            let hasTrim := or(
                eq(flag, TRIM_FLAG),
                eq(flag, TRIM_DUAL_FLAG)
            )
            mstore(
                trimInfo,
                hasTrim
            ) // hasTrim
            switch eq(hasTrim, 1)
            case 1{
                mstore(
                    add(0x20, trimInfo),
                    shr(160, and(trimData, _TRIM_RATE_MASK))
                ) // trimRate
                mstore(
                    add(0x40, trimInfo),
                    and(trimData, _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK)
                ) // trimAddress
                // get second bytes32 of trim data
                trimData := calldataload(sub(calldatasize(), add(offset, 0x40)))
                let flag2 := and(trimData, _TRIM_FLAG_MASK)
                if iszero(eq(flag, flag2)) {
                    _revertWithReason(
                        0x00000011696e76616c6964207472696d20666c61670000000000000000000000,
                        0x55
                    ) // "invalid trim flag"
                }
                let toBTrim := NO_TO_B_MODE // default toBTrim is 1 for no-toB trim when trimData exists
                if gt(and(trimData, _TO_B_TRIM_MASK), 0) {
                    toBTrim := TO_B_MODE // toB trim value when trimData exists
                }
                mstore(
                    add(0x60, trimInfo),
                    toBTrim //toBTrim
                )
                mstore(
                    add(0x80, trimInfo),
                    and(trimData, _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK)
                ) // expectAmountOut
            }
            default {
                mstore(add(0x20, trimInfo), 0) // trimRate
                mstore(add(0x40, trimInfo), 0) // trimAddress
                mstore(add(0x60, trimInfo), 0) // toBTrim
                mstore(add(0x80, trimInfo), 0) // expectAmountOut
            }
            switch eq(flag, TRIM_DUAL_FLAG)
            case 1 {
                // get third bytes32 of trim data
                trimData := calldataload(sub(calldatasize(), add(offset, 0x60)))
                let flag2 := and(trimData, _TRIM_FLAG_MASK)
                if iszero(eq(flag, flag2)) {
                    _revertWithReason(
                        0x00000011696e76616c6964207472696d20666c61670000000000000000000000,
                        0x55
                    ) // "invalid trim flag"
                }
                mstore(
                    add(0xa0, trimInfo),
                    shr(160, and(trimData, _TRIM_RATE_MASK))
                ) // chargeRate
                mstore(
                    add(0xc0, trimInfo),
                    and(trimData, _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK)
                ) // chargeAddress
            }
            default {
                mstore(add(0xa0, trimInfo), 0) // chargeRate
                mstore(add(0xc0, trimInfo), 0) // chargeAddress
            }
        }

        if (commissionInfo.isFromTokenCommission || commissionInfo.isToTokenCommission || trimInfo.hasTrim) {
            emit CommissionAndTrimInfo(
                commissionInfo.toBCommission,
                trimInfo.toBTrim,
                trimInfo.trimRate,
                trimInfo.chargeRate
            );
        }
    }

    function _getBalanceOf(
        address token,
        address user
    ) internal returns (uint256 amount) {
        assembly {
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            switch eq(token, _ETH)
            case 1 {
                amount := balance(user)
            }
            default {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x24))
                mstore(
                    freePtr,
                    0x70a0823100000000000000000000000000000000000000000000000000000000
                ) //balanceOf
                mstore(add(freePtr, 0x04), user)
                let success := staticcall(gas(), token, freePtr, 0x24, 0, 0x20)
                if eq(success, 0) {
                    _revertWithReason(
                        0x000000146765742062616c616e63654f66206661696c65640000000000000000,
                        0x58
                    ) // "get balanceOf failed"
                }
                amount := mload(0x00)
            }
        }
    }

    function _doCommissionFromToken(
        CommissionInfo memory commissionInfo,
        address payer,
        address receiver,
        uint256 inputAmount,
        bool hasTrim,
        address toToken
    ) internal override returns (address middleReceiver, uint256 balanceBefore) {
        if (commissionInfo.isToTokenCommission || hasTrim) {
            middleReceiver = address(this);
            balanceBefore = _getBalanceOf(toToken, address(this));
        } else {
            middleReceiver = receiver;
        }

        if (commissionInfo.isFromTokenCommission) {
            _doCommissionFromTokenInternal(commissionInfo, payer, inputAmount);
        }
    }

    function _doCommissionFromTokenInternal(
        CommissionInfo memory commissionInfo,
        address payer,
        uint256 inputAmount
    ) private {
        assembly ("memory-safe") {
            // https://github.com/Vectorized/solady/blob/701406e8126cfed931645727b274df303fbcd94d/src/utils/FixedPointMathLib.sol#L595
            function _mulDiv(x, y, d) -> z {
                z := mul(x, y)
                // Equivalent to `require(d != 0 && (y == 0 || x <= type(uint256).max / y))`.
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                    revert(0x1c, 0x04)
                }
                z := div(z, d)
            }
            function _safeSub(x, y) -> z {
                if lt(x, y) {
                    mstore(0x00, 0x46e72d03) // `SafeSubFailed()`.
                    revert(0x1c, 0x04)
                }
                z := sub(x, y)
            }
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            function _sendETH(to, amount) {
                if gt(amount, 0) {
                    let success := call(gas(), to, amount, 0, 0, 0, 0)
                    if eq(success, 0) {
                        _revertWithReason(
                            0x0000001b636f6d6d697373696f6e2077697468206574686572206572726f7200,
                            0x5f
                        ) // "commission with ether error"
                    }
                }
            }
            function _claimToken(token, _payer, to, amount) {
                if gt(amount, 0) {
                    let freePtr := mload(0x40)
                    mstore(0x40, add(freePtr, 0x84))
                    mstore(
                        freePtr,
                        0x0a5ea46600000000000000000000000000000000000000000000000000000000
                    ) // claimTokens
                    mstore(add(freePtr, 0x04), token)
                    mstore(add(freePtr, 0x24), _payer)
                    mstore(add(freePtr, 0x44), to)
                    mstore(add(freePtr, 0x64), amount)
                    let success := call(
                        gas(),
                        _APPROVE_PROXY,
                        0,
                        freePtr,
                        0x84,
                        0,
                        0
                    )
                    if eq(success, 0) {
                        _revertWithReason(
                            0x00000013636c61696d20746f6b656e73206661696c6564000000000000000000,
                            0x57
                        ) // "claim tokens failed"
                    }
                }
            }
            function _sendToken(token, to, amount) {
                if gt(amount, 0) {
                    let freePtr := mload(0x40)
                    mstore(0x40, add(freePtr, 0x44))
                    mstore(
                        freePtr,
                        0xa9059cbb00000000000000000000000000000000000000000000000000000000
                    ) // transfer
                    mstore(add(freePtr, 0x04), to)
                    mstore(add(freePtr, 0x24), amount)
                    let success := call(
                        gas(),
                        token,
                        0,
                        freePtr,
                        0x44,
                        0,
                        0x20
                    )
                    if and(
                        iszero(and(eq(mload(0), 1), gt(returndatasize(), 31))),
                        success
                    ) {
                        success := iszero(
                            or(iszero(extcodesize(token)), returndatasize())
                        )
                    }
                    if eq(success, 0) {
                        _revertWithReason(
                            0x0000001b7472616e7366657220746f6b656e2072656665726572206661696c00,
                            0x5f
                        ) // "transfer token referer fail"
                    }
                }
            }
            // get balance, then scale each amount according to balance, and send tokens with scaled amount
            function _sendTokenWithinBalanceAndEmitEvents(token, totalRate, referrerNum, commissionInfo_)
            {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x24))
                mstore(
                    freePtr,
                    0x70a0823100000000000000000000000000000000000000000000000000000000
                ) // balanceOf
                // get token balance of address(this)
                mstore(add(freePtr, 0x4), address())
                let success := staticcall(
                    gas(),
                    token,
                    freePtr,
                    0x24,
                    0,
                    0x20
                )
                if eq(success, 0) {
                    _revertWithReason(
                        0x000000146765742062616c616e63654f66206661696c65640000000000000000,
                        0x58
                    ) // "get balanceOf failed"
                }
                let balanceAfter := mload(0x00)
                let sendAmount := 0 // the amount of tokens already sent
                for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                    let rate := mload(add(commissionInfo_, add(0xa0, mul(i, 0x40))))
                    let amountScaled
                    switch eq(i, sub(referrerNum, 1))
                    case 1 { // last referrer
                        amountScaled := _safeSub(balanceAfter, sendAmount)
                    }
                    default { // not last referrer
                        amountScaled := _mulDiv(
                            _mulDiv(rate, WAD, totalRate),
                            balanceAfter,
                            WAD
                        )
                        if gt(amountScaled, balanceAfter) {
                            _revertWithReason(
                                0x00000014696e76616c696420616d6f756e745363616c65640000000000000000,
                                0x58
                            ) // "invalid amountScaled"
                        }
                        sendAmount := add(sendAmount, amountScaled)
                    }
                    let referrer := mload(add(commissionInfo_, add(0xc0, mul(i, 0x40))))
                    _sendToken(token, referrer, amountScaled)
                    _emitCommissionFromToken(token, amountScaled, referrer, rate)
                }
            }
            function _emitCommissionFromToken(token, amount, referrer, rate) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x80))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), amount)
                mstore(add(freePtr, 0x40), referrer)
                mstore(add(freePtr, 0x60), rate)
                log1(
                    freePtr,
                    0x80,
                    0xcd5eae9d9d0b96532bd1b7dbf6628ce436b2af735829087a03c548439f8bf850
                ) //emit CommissionFromTokenRecord(address,uint256,address,uint256)
            }

            let token := mload(add(commissionInfo, 0x40))
            let toBCommission := mload(add(commissionInfo, 0x60))
            let totalRate := 0
            let referrerNum := mload(add(commissionInfo, 0x80))
            for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                let rate := mload(add(commissionInfo, add(0xa0, mul(i, 0x40))))
                totalRate := add(totalRate, rate)
            }
            if gt(totalRate, commissionRateLimit) {
                _revertWithReason(
                    0x000000156572726f7220636f6d6d697373696f6e207261746500000000000000,
                    0x59
                ) // "error commission rate"
            }
            if eq(token, _ETH) { // commission token is ETH, the process is same between no toB mode and toB mode
                for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                    let rate := mload(add(commissionInfo, add(0xa0, mul(i, 0x40))))
                    let referrer := mload(add(commissionInfo, add(0xc0, mul(i, 0x40))))
                    let amount := div(
                        mul(inputAmount, rate),
                        sub(DENOMINATOR, totalRate)
                    )
                    _sendETH(referrer, amount)
                    _emitCommissionFromToken(_ETH, amount, referrer, rate)
                }
            }
            if and(iszero(eq(token, _ETH)), eq(toBCommission, NO_TO_B_MODE)) { // commission token is ERC20 with no toB mode
                for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                    let rate := mload(add(commissionInfo, add(0xa0, mul(i, 0x40))))
                    let referrer := mload(add(commissionInfo, add(0xc0, mul(i, 0x40))))
                    let amount := div(
                        mul(inputAmount, rate),
                        sub(DENOMINATOR, totalRate)
                    )
                    _claimToken(token, payer, referrer, amount)
                    _emitCommissionFromToken(token, amount, referrer, rate)
                }
            }
            if and(iszero(eq(token, _ETH)), eq(toBCommission, TO_B_MODE)) { // commission token is ERC20 with toB mode
                let totalAmount := div(
                    mul(inputAmount, totalRate),
                    sub(DENOMINATOR, totalRate)
                )
                _claimToken(token, payer, address(), totalAmount)
                _sendTokenWithinBalanceAndEmitEvents(
                    token,
                    totalRate,
                    referrerNum,
                    commissionInfo
                )
            }
        }
    }

    function _doCommissionAndTrimToToken(
        CommissionInfo memory commissionInfo,
        address receiver,
        uint256 balanceBefore,
        address toToken,
        TrimInfo memory trimInfo
    ) internal override returns (uint256 totalAmount) {
        if (!commissionInfo.isToTokenCommission && !trimInfo.hasTrim) {
            return 0;
        }
        uint256 balanceAfter = _getBalanceOf(toToken, address(this));
        assembly ("memory-safe") {
            // https://github.com/Vectorized/solady/blob/701406e8126cfed931645727b274df303fbcd94d/src/utils/FixedPointMathLib.sol#L595
            function _mulDiv(x, y, d) -> z {
                z := mul(x, y)
                // Equivalent to `require(d != 0 && (y == 0 || x <= type(uint256).max / y))`.
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                    revert(0x1c, 0x04)
                }
                z := div(z, d)
            }
            function _safeSub(x, y) -> z {
                if lt(x, y) {
                    mstore(0x00, 0x46e72d03) // `SafeSubFailed()`.
                    revert(0x1c, 0x04)
                }
                z := sub(x, y)
            }
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            function _sendETH(to, amount) {
                if gt(amount, 0) {
                    let success := call(gas(), to, amount, 0, 0, 0, 0)
                    if eq(success, 0) {
                        _revertWithReason(
                            0x0000001173656e64206574686572206661696c65640000000000000000000000,
                            0x55
                        ) // "send ether failed"
                    }
                }
            }
            function _sendToken(token, to, amount) {
                if gt(amount, 0) {
                    let freePtr := mload(0x40)
                    mstore(0x40, add(freePtr, 0x44))
                    mstore(
                        freePtr,
                        0xa9059cbb00000000000000000000000000000000000000000000000000000000
                    ) // transfer
                    mstore(add(freePtr, 0x04), to)
                    mstore(add(freePtr, 0x24), amount)
                    let success := call(
                        gas(),
                        token,
                        0,
                        freePtr,
                        0x44,
                        0,
                        0x20
                    )
                    if and(
                        iszero(and(eq(mload(0), 1), gt(returndatasize(), 31))),
                        success
                    ) {
                        success := iszero(
                            or(iszero(extcodesize(token)), returndatasize())
                        )
                    }
                    if eq(success, 0) {
                        _revertWithReason(
                            0x000000157472616e7366657220746f6b656e206661696c656400000000000000,
                            0x59
                        ) // "transfer token failed"
                    }
                }
            }
            function _emitCommissionToToken(token, amount, referrer, rate) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x80))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), amount)
                mstore(add(freePtr, 0x40), referrer)
                mstore(add(freePtr, 0x60), rate)
                log1(
                    freePtr,
                    0x80,
                    0x3cfb523a4c38d88561dd3bf04805a31715c8b5fc468a03b8d684356f360dea99
                ) //emit CommissionToTokenRecord(address,uint256,address,uint256)
            }
            function _emitPositiveSlippageTrimRecord(token, trimAmount, trimAddress) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x60))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), trimAmount)
                mstore(add(freePtr, 0x40), trimAddress)
                log1(
                    freePtr,
                    0x60,
                    0x7bec7d55a62a7a7b8068f1533e2a3bbf727b3e2e57f30c576fe159da60e09a65
                ) // emit PositiveSlippageTrimRecord(address,uint256,address)
            }
            function _emitPositiveSlippageChargeRecord(token, chargeAmount, chargeAddress) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x60))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), chargeAmount)
                mstore(add(freePtr, 0x40), chargeAddress)
                log1(
                    freePtr,
                    0x60,
                    0xfd08115c8e43d2a49d95ee18d7f69b8bbac60bd368c73cf22d30664a22a0626d
                ) // emit PositiveSlippageChargeRecord(address,uint256,address)
            }
            function _processCommission(commissionInfo_, toToken_, inputAmount) -> commissionAmount {
                let referrerNum := mload(add(commissionInfo_, 0x80)) // commissionInfo.referrerNum
                let totalRate := 0
                for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                    let rate := mload(add(commissionInfo_, add(0xa0, mul(i, 0x40))))
                    totalRate := add(totalRate, rate)
                }
                if gt(totalRate, commissionRateLimit) {
                    _revertWithReason(
                        0x000000156572726f7220636f6d6d697373696f6e207261746500000000000000,
                        0x59
                    ) // "error commission rate"
                }
                commissionAmount := 0
                switch eq(toToken_, _ETH)
                case 1 { // commission token is ETH
                    for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                        let rate := mload(add(commissionInfo_, add(0xa0, mul(i, 0x40))))
                        let amount := _mulDiv(inputAmount, rate, DENOMINATOR)
                        let referrer := mload(add(commissionInfo_, add(0xc0, mul(i, 0x40))))
                        _sendETH(referrer, amount)
                        _emitCommissionToToken(_ETH, amount, referrer, rate)
                        commissionAmount := add(commissionAmount, amount)
                    }
                }
                default { // commission token is ERC20
                    for { let i := 0 } lt(i, referrerNum) { i := add(i, 1) } {
                        let rate := mload(add(commissionInfo_, add(0xa0, mul(i, 0x40))))
                        let amount := _mulDiv(inputAmount, rate, DENOMINATOR)
                        let referrer := mload(add(commissionInfo_, add(0xc0, mul(i, 0x40))))
                        _sendToken(toToken_, referrer, amount)
                        _emitCommissionToToken(toToken_, amount, referrer, rate)
                        commissionAmount := add(commissionAmount, amount)
                    }
                }
            } 
            function _processTrim(trimInfo_, toToken_, inputAmount) -> trimAmount {
                let trimRate := mload(add(trimInfo_, 0x20)) // trimInfo.trimRate
                let chargeRate := mload(add(trimInfo_, 0xa0)) // trimInfo.chargeRate
                // require(trimInfo.trimRate <= TRIM_RATE_LIMIT, "error trim rate");
                if gt(trimRate, TRIM_RATE_LIMIT) {
                    _revertWithReason(
                        0x0000000f6572726f72207472696d207261746500000000000000000000000000,
                        0x53
                    ) // "error trim rate"
                }
                // require(trimInfo.chargeRate <= TRIM_DENOMINATOR, "error charge rate");
                if gt(chargeRate, TRIM_DENOMINATOR) {
                    _revertWithReason(
                        0x000000116572726f722063686172676520726174650000000000000000000000,
                        0x55
                    ) // "error charge rate"
                }
                // uint256 trimAmount = inputAmount - trimInfo.expectAmountOut;
                let expectAmountOut := mload(add(trimInfo_, 0x80)) // trimInfo.expectAmountOut
                trimAmount := sub(inputAmount, expectAmountOut)
                // uint256 allowedMaxTrimAmount = inputAmount * trimInfo.trimRate / TRIM_DENOMINATOR;
                let allowedMaxTrimAmount := _mulDiv(inputAmount, trimRate, TRIM_DENOMINATOR)
                // trimAmount = min(trimAmount, allowedMaxTrimAmount)
                if gt(trimAmount, allowedMaxTrimAmount) {
                    trimAmount := allowedMaxTrimAmount
                }

                // send token and emit events
                // actualChargeAmount = trimAmount * chargeRate / TRIM_DENOMINATOR
                let actualChargeAmount := _mulDiv(trimAmount, chargeRate, TRIM_DENOMINATOR)
                // actualTrimAmount = trimAmount - actualChargeAmount
                let actualTrimAmount := sub(trimAmount, actualChargeAmount)
                switch eq(toToken_, _ETH)
                case 1 { // commission token is ETH
                    let trimAddress := mload(add(trimInfo_, 0x40)) // trimInfo.trimAddress
                    _sendETH(trimAddress, actualTrimAmount)
                    _emitPositiveSlippageTrimRecord(_ETH, actualTrimAmount, trimAddress)

                    let chargeAddress := mload(add(trimInfo_, 0xc0)) // trimInfo.chargeAddress
                    _sendETH(chargeAddress, actualChargeAmount)
                    _emitPositiveSlippageChargeRecord(_ETH, actualChargeAmount, chargeAddress)
                }
                case 0 { // commission token is ERC20
                    let trimAddress := mload(add(trimInfo_, 0x40)) // trimInfo.trimAddress
                    _sendToken(toToken_, trimAddress, actualTrimAmount)
                    _emitPositiveSlippageTrimRecord(toToken_, actualTrimAmount, trimAddress)

                    let chargeAddress := mload(add(trimInfo_, 0xc0)) // trimInfo.chargeAddress
                    _sendToken(toToken_, chargeAddress, actualChargeAmount)
                    _emitPositiveSlippageChargeRecord(toToken_, actualChargeAmount, chargeAddress)
                }
            }

            // require(balanceAfter > balanceBefore, "invalid balance after");
            if or(gt(balanceBefore, balanceAfter), eq(balanceAfter, balanceBefore)) {
                _revertWithReason(
                    0x00000015696e76616c69642062616c616e636520616674657200000000000000,
                    0x59
                ) // "invalid balance after"
            }
            let inputAmount := sub(balanceAfter, balanceBefore)

            // process commission
            let flag := mload(add(commissionInfo, 0x20)) // commissionInfo.isToTokenCommission
            if gt(flag, 0) { // commissionInfo.isToTokenCommission == True
                let commissionAmount := _processCommission(commissionInfo, toToken, inputAmount)
                inputAmount := sub(inputAmount, commissionAmount)
                totalAmount := commissionAmount
            }

            // process trim
            flag := mload(add(trimInfo, 0x00)) // trimInfo.hasTrim
            let expectAmountOut := mload(add(trimInfo, 0x80)) // trimInfo.expectAmountOut
            if and(gt(flag, 0), gt(inputAmount, expectAmountOut)) { // trimInfo.hasTrim == True && inputAmount > trimInfo.expectAmountOut
                let trimAmount := _processTrim(trimInfo, toToken, inputAmount)
                inputAmount := sub(inputAmount, trimAmount)
                totalAmount := add(totalAmount, trimAmount)
            }

            // transfer toToken to receiver
            switch eq(toToken, _ETH)
            case 1 {
                _sendETH(shr(96, shl(96, receiver)), inputAmount)
            }
            default {
                _sendToken(toToken, shr(96, shl(96, receiver)), inputAmount)
            }
        }
    }

    function _validateCommissionInfo(
        CommissionInfo memory commissionInfo,
        address fromToken,
        address toToken,
        uint256 mode
    ) internal pure override {
        assembly ("memory-safe") {
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }

            // if ((
            //     (mode & _MODE_NO_TRANSFER) != 0 
            // || (mode & _MODE_BY_INVEST) != 0
            // || (mode & _MODE_PERMIT2) != 0
            // )
            // && commissionInfo.isFromTokenCommission) {
            //     revert("From commission not support");
            // }
            let flag := or(
                or(
                    gt(and(mode, _MODE_NO_TRANSFER), 0),
                    gt(and(mode, _MODE_BY_INVEST), 0)
                ),
                gt(and(mode, _MODE_PERMIT2), 0)
            )
            let isFromTokenCommission := mload(add(commissionInfo, 0x00)) // commissionInfo.isFromTokenCommission
            if and(flag, isFromTokenCommission) {
                _revertWithReason(
                    0x0000001b46726f6d20636f6d6d697373696f6e206e6f7420737570706f727400,
                    0x5f
                ) // "From commission not support"
            }

            // if(fromToken == toToken) {
            //     revert("Invalid tokens");
            // }
            if eq(fromToken, toToken) {
                _revertWithReason(
                    0x0000000e496e76616c696420746f6b656e730000000000000000000000000000,
                    0x52
                ) // "Invalid tokens"
            }

            // if (commissionInfo.isFromTokenCommission && commissionInfo.isToTokenCommission) {
            //     revert("Invalid commission direction");
            // }
            let isToTokenCommission := mload(add(commissionInfo, 0x20)) // commissionInfo.isToTokenCommission
            if and(isToTokenCommission, isFromTokenCommission) {
                _revertWithReason(
                    0x0000001c496e76616c696420636f6d6d697373696f6e20646972656374696f6e,
                    0x60
                ) // "Invalid commission direction"
            }

            // require(
            //     (commissionInfo.isFromTokenCommission && commissionInfo.token == fromToken)
            //         || (commissionInfo.isToTokenCommission && commissionInfo.token == toToken)
            //         || (!commissionInfo.isFromTokenCommission && !commissionInfo.isToTokenCommission),
            //     "Invalid commission info"
            // );
            let token := mload(add(commissionInfo, 0x40)) // commissionInfo.token
            flag := and(isFromTokenCommission, eq(token, fromToken))
            flag := or(flag, and(isToTokenCommission, eq(token, toToken)))
            flag := or(flag, and(iszero(isFromTokenCommission), iszero(isToTokenCommission)))
            if iszero(flag) {
                _revertWithReason(
                    0x00000017496e76616c696420636f6d6d697373696f6e20696e666f0000000000,
                    0x5b
                ) // "Invalid commission info"
            }
        }
    }
}

// File: contracts/8/libraries/EthReceiver.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Base contract with common payable logics
abstract contract EthReceiver {
  receive() external payable {
    // solhint-disable-next-line avoid-tx-origin
    require(msg.sender != tx.origin, "ETH deposit rejected");
  }
}


// File: contracts/8/libraries/UniswapTokenInfoHelper.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CommonUtils} from "./CommonUtils.sol";
import {IUni} from "../interfaces/IUni.sol";
import {IUniV3} from "../interfaces/IUniV3.sol";

/// @title UniswapTokenInfoHelper
/// @notice Helper functions for getting fromToken and toToken from
/// encoded pools array of unxswap and uniswapV3Swap methods.
/// @dev This contract will be used in DexRouter and DexRouterExactOut. So the
/// masks are re-defined here and keep the same as in the original contracts.
abstract contract UniswapTokenInfoHelper is CommonUtils {
    function _getUnxswapTokenInfo(bool sendValue, bytes32[] calldata pools)
        internal
        view
        returns (address fromToken, address toToken)
    {
        require(pools.length > 0, "pools must be greater than 0");

        // get fromToken
        address firstPoolAddr = address(uint160(uint256(pools[0]) & _ADDRESS_MASK));
        // default: token0 to token1; reverse: token1 to token0
        bool firstReversed = (uint256(pools[0]) & _REVERSE_MASK) != 0;
        fromToken = firstReversed ? IUni(firstPoolAddr).token1() : IUni(firstPoolAddr).token0();
        if (fromToken == _WETH && sendValue) {
            fromToken = _ETH;
        }

        // get toToken
        bytes32 lastPool = pools[pools.length - 1];
        address lastPoolAddr = address(uint160(uint256(lastPool) & _ADDRESS_MASK));
        bool lastReversed = (uint256(lastPool) & _REVERSE_MASK) != 0;
        toToken = lastReversed ? IUni(lastPoolAddr).token0() : IUni(lastPoolAddr).token1();
        bool isWeth = (uint256(lastPool) & _WETH_MASK) != 0; // unwrap weth to eth eventually
        if (toToken == _WETH && isWeth) {
            toToken = _ETH;
        }
    }


    function _getUniswapV3TokenInfo(bool sendValue, uint256[] calldata pools)
        internal
        view
        returns (address fromToken, address toToken)
    {
        require(pools.length > 0, "pools must be greater than 0");

        // get fromToken
        address firstPoolAddr = address(uint160(pools[0] & _ADDRESS_MASK));
        bool firstZeroForOne = (pools[0] & _ONE_FOR_ZERO_MASK) == 0;
        fromToken = firstZeroForOne ? IUniV3(firstPoolAddr).token0() : IUniV3(firstPoolAddr).token1();
        if (fromToken == _WETH && sendValue) {
            fromToken = _ETH;
        }

        // get toToken
        uint256 lastPool = pools[pools.length - 1];
        address lastPoolAddr = address(uint160(lastPool & _ADDRESS_MASK));
        bool lastZeroForOne = (lastPool & _ONE_FOR_ZERO_MASK) == 0;
        toToken = lastZeroForOne ? IUniV3(lastPoolAddr).token1() : IUniV3(lastPoolAddr).token0();
        bool unwrapWeth = (lastPool & _WETH_UNWRAP_MASK) != 0; // unwrap weth to eth eventually
        if (toToken == _WETH && unwrapWeth) {
            toToken = _ETH;
        }
    }
}

// File: contracts/8/libraries/CommonLib.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./CommonUtils.sol";
import "./SafeERC20.sol";
import "./UniversalERC20.sol";
import "../interfaces/IAdapter.sol";
import "../interfaces/IApproveProxy.sol";
import "../interfaces/IWNativeRelayer.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IERC20.sol";


/// @title Base contract with common permit handling logics
abstract contract CommonLib is CommonUtils {
    using UniversalERC20 for IERC20;

    function _exeAdapter(
        bool reverse,
        address adapter,
        address to,
        address poolAddress,
        bytes memory moreinfo,
        address refundTo
    ) internal {
        if (reverse) {
            (bool s, bytes memory res) = address(adapter).call(
                abi.encodePacked(
                    abi.encodeWithSelector(
                        IAdapter.sellQuote.selector,
                        to,
                        poolAddress,
                        moreinfo
                    ),
                    ORIGIN_PAYER + uint(uint160(refundTo))
                )
            );
            if (!s) {
                _revert(res);
            }
        } else {
            (bool s, bytes memory res) = address(adapter).call(
                abi.encodePacked(
                    abi.encodeWithSelector(
                        IAdapter.sellBase.selector,
                        to,
                        poolAddress,
                        moreinfo
                    ),
                    ORIGIN_PAYER + uint(uint160(refundTo))
                )
            );
            if (!s) {
                _revert(res);
            }
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with "FailedCall".
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/c64a1edb67b6e3f4a15cca8909c9482ad33a02b0/contracts/utils/Address.sol#L135-L149
     */
    function _revert(bytes memory returndata) internal pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        } else {
            revert("adaptor call failed");
        }
    }

    /// @notice Transfers tokens internally within the contract.
    /// @param payer The address of the payer.
    /// @param to The address of the receiver.
    /// @param fromTokenWithMode FromToken with mode encoded in high bits
    /// @param amount The amount of tokens to be transferred.
    /// @dev Handles the transfer of ERC20 tokens or native tokens within the contract.
    function _transferInternal(
        address payer,
        address to,
        uint256 fromTokenWithMode,
        uint256 amount
    ) internal {
        address token = address(uint160(fromTokenWithMode & _ADDRESS_MASK));
        uint256 mode = fromTokenWithMode & _TRANSFER_MODE_MASK;
        
        if (mode == _MODE_NO_TRANSFER) {
            return;
        } else if (mode == _MODE_BY_INVEST) {
            SafeERC20.safeTransfer(IERC20(token), to, amount);
            return;
        } else if (mode == _MODE_PERMIT2) {
            // Permit2 mode - reserved for future implementation
            return;
        } else {
            if (payer == address(this)) {
                SafeERC20.safeTransfer(IERC20(token), to, amount);
            } else {
                IApproveProxy(_APPROVE_PROXY).claimTokens(token, payer, to, amount);
            }
        }
    }

    /// @notice Transfers the specified token to the user.
    /// @param token The address of the token to be transferred.
    /// @param to The address of the receiver.
    /// @dev Handles the withdrawal of tokens to the user, converting WETH to ETH if necessary.
    function _transferTokenToUser(address token, address to) internal {
        if ((IERC20(token).isETH())) {
            uint256 wethBal = IERC20(address(uint160(_WETH))).balanceOf(
                address(this)
            );
            if (wethBal > 0) {
                IWETH(address(uint160(_WETH))).transfer(
                    _WNATIVE_RELAY,
                    wethBal
                );
                IWNativeRelayer(_WNATIVE_RELAY).withdraw(wethBal);
            }
            if (to != address(this)) {
                uint256 ethBal = address(this).balance;
                if (ethBal > 0) {
                    (bool success, ) = payable(to).call{value: ethBal}("");
                    require(success, "transfer native token failed");
                }
            }
        } else {
            if (to != address(this)) {
                uint256 bal = IERC20(token).balanceOf(address(this));
                if (bal > 0) {
                    SafeERC20.safeTransfer(IERC20(token), to, bal);
                }
            }
        }
    }

    /// @notice Converts a uint256 value into an address.
    /// @param param The uint256 value to be converted.
    /// @return result The address obtained from the conversion.
    /// @dev This function is used to extract an address from a uint256,
    /// typically used when dealing with low-level data operations or when addresses are packed into larger data types.
    function _bytes32ToAddress(
        uint256 param
    ) internal pure returns (address result) {
        assembly {
            result := and(param, _ADDRESS_MASK)
        }
    }
}


// File: contracts/8/DagRouter.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./libraries/CommonLib.sol";
import "./libraries/UniversalERC20.sol";
import "./interfaces/IERC20.sol";

abstract contract DagRouter is CommonLib {

    using UniversalERC20 for IERC20;

    /// @notice Core DAG algorithm data structure
    /// @dev Maintains the state of the DAG during execution
    struct SwapState {
        /// @notice the number of nodes need to be processed
        uint256 nodeNum;
        /// @notice the refundTo address of the DAG
        address refundTo;
    }

    /// @notice The fromTokenAmount will not must be greater than 0, cause for some protocols the fromTokenAmount needs to be 0 to skip token transfer like fourmeme. 
    function _dagSwapInternal(
        BaseRequest calldata baseRequest,
        RouterPath[] calldata paths,
        address payer,
        address refundTo,
        address receiver
    ) internal {
        // 1. check and process ETH
        BaseRequest memory _baseRequest = baseRequest;

        address fromToken = _bytes32ToAddress(_baseRequest.fromToken);

        address firstNodeToken = _bytes32ToAddress(paths[0].fromToken);

        // In order to deal with ETH/WETH transfer rules in a unified manner,
        // we do not need to judge according to fromToken.
        if (IERC20(fromToken).isETH()) {
            require(firstNodeToken == _WETH, "firstToken mismatch");
            IWETH(_WETH).deposit{
                value: _baseRequest.fromTokenAmount
            }();
            payer = address(this);
        } else {
            require(firstNodeToken == fromToken, "firstToken mismatch");
            require(msg.value == 0, "value must be 0");
        }

        // 2. execute dag swap
        // For BY_INVEST mode, the fromTokenAmount still needs to be fromToken balance to keep consistent with smartSwapByInvestWithRefund.
        // In later version, the scaling of fromTokenAmount will be completed by the earn contract, then we will remove this logic.
        uint256 firstNodeBalance = _baseRequest.fromTokenAmount;
        if (paths[0].fromToken & _TRANSFER_MODE_MASK == _MODE_BY_INVEST) {
            firstNodeBalance = IERC20(firstNodeToken).balanceOf(address(this));
        }
        _exeDagSwap(payer, receiver, refundTo, firstNodeBalance, IERC20(_baseRequest.toToken).isETH(), paths);

        // 3. transfer tokens to receiver
        _transferTokenToUser(_baseRequest.toToken, receiver);
    }

    /// @notice The core logic to execute the DAG swap. For the first node, the payer should use passed value.
    /// For the non-first node, the payer should always be address(this) cause the to address of the middle swap is address(this).
    function _exeDagSwap(
        address payer,
        address receiver,
        address refundTo,
        uint256 firstNodeBalance,
        bool isToNative,
        RouterPath[] calldata paths
    ) private {
        uint256 nodeNum = paths.length;
        SwapState memory swapState = _initSwapState(nodeNum, refundTo);

        // execute nodes
        for (uint256 i = 0; i < nodeNum;) {
            if (i != 0) { // reset payer for non-first node
                payer = address(this);
            }

            _exeNode(payer, receiver, firstNodeBalance, i, isToNative, paths[i], swapState);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Initialize the swap state for the DAG execution
    function _initSwapState(
        uint256 _nodeNum,
        address _refundTo
    ) private pure returns (SwapState memory state) {
        state.nodeNum = _nodeNum;
        state.refundTo = _refundTo;
    }

    /// @notice The core logic to execute the each node
    function _exeNode(
        address payer,
        address receiver,
        uint256 nodeBalance,
        uint256 nodeIndex,
        bool isToNative,
        RouterPath calldata path,
        SwapState memory swapState
    ) private {
        uint256 totalWeight;
        uint256 accAmount;
        address fromToken = _bytes32ToAddress(path.fromToken);

        require(path.mixAdapters.length > 0, "edge length must be > 0");
        require(
            path.mixAdapters.length == path.rawData.length &&
            path.mixAdapters.length == path.extraData.length &&
            path.mixAdapters.length == path.assetTo.length,
            "path length mismatch"
        );

        // to get the nodeBalance for non-first node, the balance of the first node is the original passed value
        if (nodeIndex != 0) {
            nodeBalance = IERC20(fromToken).balanceOf(address(this));
            require(nodeBalance > 0, "node balance must be > 0");
        }

        // execute edges
        for (uint256 i = 0; i < path.mixAdapters.length;) {
            uint256 inputIndex;
            uint256 outputIndex;
            uint256 weight;

            // 1. get inputIndex, outputIndex, weight and verify
            {
                bytes32 rawData = bytes32(path.rawData[i]);
                assembly {
                    weight := shr(160, and(rawData, _WEIGHT_MASK))
                    inputIndex := shr(184, and(rawData, _INPUT_INDEX_MASK))
                    outputIndex := shr(176, and(rawData, _OUTPUT_INDEX_MASK))
                }

                require(inputIndex == nodeIndex, "node inputIndex inconsistent");
                require(inputIndex < outputIndex && outputIndex <= swapState.nodeNum, "node index out of range");

                totalWeight += weight;
                if (i == path.mixAdapters.length - 1) {
                    require(
                        totalWeight == 10_000,
                        "totalWeight must be 10000"
                    );
                }
            }

            // 2. transfer fromToken from payer to assetTo of edge
            {
                uint256 _fromTokenAmount;
                if (i == path.mixAdapters.length - 1) {
                    _fromTokenAmount = nodeBalance - accAmount;
                } else {
                    _fromTokenAmount = (nodeBalance * weight) / 10_000;
                    accAmount += _fromTokenAmount;
                }
                if (_fromTokenAmount > 0) {
                    _transferInternal(
                        payer,
                        path.assetTo[i],
                        path.fromToken,
                        _fromTokenAmount
                    );
                }
            }

            // 3. execute single swap
            {
                address to = address(this);
                if (outputIndex == swapState.nodeNum && !isToNative) {
                    to = receiver;
                }
                _exeEdge(
                    path.rawData[i],
                    path.mixAdapters[i],
                    path.extraData[i],
                    to,
                    swapState.refundTo
                );
            }

            unchecked {
                ++i;
            }
        }
    }

    function _exeEdge(
        uint256 rawData,
        address mixAdapter,
        bytes memory extraData,
        address to,
        address refundTo
    ) private {
        bool reverse;
        address poolAddress;
        assembly {
            poolAddress := and(rawData, _ADDRESS_MASK)
            reverse := and(rawData, _REVERSE_MASK)
        }

        _exeAdapter(
            reverse,
            mixAdapter,
            to,
            poolAddress,
            extraData,
            refundTo
        );
    }
}

// File: contracts/8/interfaces/IUni.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

interface IUni {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function token0() external view returns (address);

    function token1() external view returns (address);

    function sync() external;
}


// File: contracts/8/libraries/UniversalERC20.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "./SafeMath.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20} from "./SafeERC20.sol";

library UniversalERC20 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 private constant ETH_ADDRESS =
        IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    function universalTransfer(
        IERC20 token,
        address payable to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            if (isETH(token)) {
                to.transfer(amount);
            } else {
                token.safeTransfer(to, amount);
            }
        }
    }

    function universalTransferFrom(
        IERC20 token,
        address from,
        address payable to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            token.safeTransferFrom(from, to, amount);
        }
    }

    function universalApproveMax(
        IERC20 token,
        address to,
        uint256 amount
    ) internal {
        uint256 allowance = token.allowance(address(this), to);
        if (allowance < amount) {
            token.forceApprove(to, type(uint256).max);
        }
    }

    function universalBalanceOf(IERC20 token, address who)
        internal
        view
        returns (uint256)
    {
        if (isETH(token)) {
            return who.balance;
        } else {
            return token.balanceOf(who);
        }
    }

    function tokenBalanceOf(IERC20 token, address who)
        internal
        view
        returns (uint256)
    {
        return token.balanceOf(who);
    }

    function isETH(IERC20 token) internal pure returns (bool) {
        return token == ETH_ADDRESS;
    }
}


// File: contracts/8/libraries/CommonUtils.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "../interfaces/IDexRouter.sol";
/// @title Base contract with common permit handling logics
abstract contract CommonUtils is IDexRouter {
    address internal constant _ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 internal constant _ADDRESS_MASK =
        0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
    uint256 internal constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant _ORDER_ID_MASK =
        0xffffffffffffffffffffffff0000000000000000000000000000000000000000;
    uint256 internal constant _WEIGHT_MASK =
        0x00000000000000000000ffff0000000000000000000000000000000000000000;
    uint256 internal constant _CALL_GAS_LIMIT = 5000;
    uint256 internal constant ORIGIN_PAYER =
        0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;
    uint256 internal constant SWAP_AMOUNT =
        0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff;
    uint256 internal constant _WETH_MASK =
        0x4000000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant _ONE_FOR_ZERO_MASK = 1 << 255; // Mask for identifying if the swap is one-for-zero
    uint256 internal constant _WETH_UNWRAP_MASK = 1 << 253; // Mask for identifying if WETH should be unwrapped to ETH

    uint256 internal constant _MODE_LEGACY = 0;
    uint256 internal constant _MODE_NO_TRANSFER = 1 << 251;
    uint256 internal constant _MODE_BY_INVEST = 1 << 250;
    uint256 internal constant _MODE_PERMIT2 = 1 << 249;
    
    uint256 internal constant _TRANSFER_MODE_MASK = 0x0E00000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant _INPUT_INDEX_MASK =
        0x0000000000000000ff0000000000000000000000000000000000000000000000;
    uint256 internal constant _OUTPUT_INDEX_MASK =
        0x000000000000000000ff00000000000000000000000000000000000000000000;

    /// @dev WETH address is network-specific and needs to be changed before deployment.
    /// It can not be moved to immutable as immutables are not supported in assembly
    // ETH:     C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    // BSC:     bb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    // OEC:     8f8526dbfd6e38e3d8307702ca8469bae6c56c15
    // LOCAL:   5FbDB2315678afecb367f032d93F642f64180aa3
    // LOCAL2:  02121128f1Ed0AdA5Df3a87f42752fcE4Ad63e59
    // POLYGON: 0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
    // AVAX:    B31f66AA3C1e785363F0875A1B74E27b85FD66c7
    // FTM:     21be370D5312f44cB42ce377BC9b8a0cEF1A4C83
    // ARB:     82aF49447D8a07e3bd95BD0d56f35241523fBab1
    // OP:      4200000000000000000000000000000000000006
    // CRO:     5C7F8A570d578ED84E63fdFA7b1eE72dEae1AE23
    // CFX:     14b2D3bC65e74DAE1030EAFd8ac30c533c976A9b
    // POLYZK   4F9A0e7FD2Bf6067db6994CF12E4495Df938E6e9
    address public constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // address public constant _WETH = 0x5FbDB2315678afecb367f032d93F642f64180aa3;    // hardhat1
    // address public constant _WETH = 0x707531c9999AaeF9232C8FEfBA31FBa4cB78d84a;    // hardhat2

    // ETH:     70cBb871E8f30Fc8Ce23609E9E0Ea87B6b222F58
    // ETH-DEV：02D0131E5Cc86766e234EbF1eBe33444443b98a3
    // BSC:     d99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98
    // OEC:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // LOCAL:   e7f1725E7734CE288F8367e1Bb143E90bb3F0512
    // LOCAL2:  95D7fF1684a8F2e202097F28Dc2e56F773A55D02
    // POLYGON: 40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // AVAX:    70cBb871E8f30Fc8Ce23609E9E0Ea87B6b222F58
    // FTM:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // ARB:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // OP:      100F3f74125C8c724C7C0eE81E4dd5626830dD9a
    // CRO:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // CFX:     100F3f74125C8c724C7C0eE81E4dd5626830dD9a
    // POLYZK   1b5d39419C268b76Db06DE49e38B010fbFB5e226
    address public constant _APPROVE_PROXY = 0x70cBb871E8f30Fc8Ce23609E9E0Ea87B6b222F58;
    // address public constant _APPROVE_PROXY = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;    // hardhat1
    // address public constant _APPROVE_PROXY = 0x2538a10b7fFb1B78c890c870FC152b10be121f04;    // hardhat2

    // ETH:     5703B683c7F928b721CA95Da988d73a3299d4757
    // BSC:     0B5f474ad0e3f7ef629BD10dbf9e4a8Fd60d9A48
    // OEC:     d99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98
    // LOCAL:   D49a0e9A4CD5979aE36840f542D2d7f02C4817Be
    // LOCAL2:  11457D5b1025D162F3d9B7dBeab6E1fBca20e043
    // POLYGON: f332761c673b59B21fF6dfa8adA44d78c12dEF09
    // AVAX:    3B86917369B83a6892f553609F3c2F439C184e31
    // FTM:     40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // ARB:     d99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98
    // OP:      40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // CRO:     40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // CFX:     40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // POLYZK   d2F0aC2012C8433F235c8e5e97F2368197DD06C7
    address public constant _WNATIVE_RELAY = 0x5703B683c7F928b721CA95Da988d73a3299d4757;
    // address public constant _WNATIVE_RELAY = 0x0B306BF915C4d645ff596e518fAf3F9669b97016;   // hardhat1
    // address public constant _WNATIVE_RELAY = 0x6A47346e722937B60Df7a1149168c0E76DD6520f;   // hardhat2
}


// File: contracts/8/interfaces/IUniswapV3SwapCallback.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Callback for IUniswapV3PoolActions#swap
/// @notice Any contract that calls IUniswapV3PoolActions#swap must implement this interface
interface IUniswapV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}


// File: contracts/8/interfaces/IUniV3.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

interface IUniV3 {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);

    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6
    /// @return The fee
    function fee() external view returns (uint24);
}


// File: contracts/8/libraries/Address.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
        // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
        // for accounts without code, i.e. `keccak256('')`
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            codehash := extcodehash(account)
        }
        return (codehash != accountHash && codehash != 0x0);
    }

    /**
     * @dev Converts an `address` into `address payable`. Note that this is
     * simply a type cast: the actual underlying value is not changed.
     *
     * _Available since v2.4.0._
     */
    function toPayable(address account)
        internal
        pure
        returns (address payable)
    {
        return payable(account);
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     *
     * _Available since v2.4.0._
     */
    function sendValue(address recipient, uint256 amount) internal {
        require(
            address(this).balance >= amount,
            "Address: insufficient balance"
        );

        // solhint-disable-next-line avoid-call-value
        (bool success, ) = recipient.call{value: amount}("");
        require(
            success,
            "Address: unable to send value, recipient may have reverted"
        );
    }
}


// File: contracts/8/libraries/RouterErrors.sol
/// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

library RouterErrors {
    error ReturnAmountIsNotEnough();
    error InvalidMsgValue();
    error ERC20TransferFailed();
    error EmptyPools();
    error InvalidFromToken();
    error MsgValuedNotRequired();
}

// File: contracts/8/libraries/SafeCast.sol
/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {CustomRevert} from "./CustomRevert.sol";

/**
 * @dev Wrappers over Solidity's uintXX/intXX casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 *
 * Can be combined with {SafeMath} and {SignedSafeMath} to extend it to smaller types, by performing
 * all math on `uint256` and `int256` and then downcasting.
 */
library SafeCast {
    error SafeCastOverflow();
    using CustomRevert for bytes4;
    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     *
     * _Available since v4.7._
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        require(value <= type(uint248).max, "SafeCast: value doesn't fit in 248 bits");
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     *
     * _Available since v4.7._
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        require(value <= type(uint240).max, "SafeCast: value doesn't fit in 240 bits");
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     *
     * _Available since v4.7._
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        require(value <= type(uint232).max, "SafeCast: value doesn't fit in 232 bits");
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     *
     * _Available since v4.2._
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        require(value <= type(uint224).max, "SafeCast: value doesn't fit in 224 bits");
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     *
     * _Available since v4.7._
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        require(value <= type(uint216).max, "SafeCast: value doesn't fit in 216 bits");
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     *
     * _Available since v4.7._
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        require(value <= type(uint208).max, "SafeCast: value doesn't fit in 208 bits");
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     *
     * _Available since v4.7._
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        require(value <= type(uint200).max, "SafeCast: value doesn't fit in 200 bits");
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     *
     * _Available since v4.7._
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        require(value <= type(uint192).max, "SafeCast: value doesn't fit in 192 bits");
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     *
     * _Available since v4.7._
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        require(value <= type(uint184).max, "SafeCast: value doesn't fit in 184 bits");
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     *
     * _Available since v4.7._
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        require(value <= type(uint176).max, "SafeCast: value doesn't fit in 176 bits");
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     *
     * _Available since v4.7._
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        require(value <= type(uint168).max, "SafeCast: value doesn't fit in 168 bits");
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     *
     * _Available since v4.7._
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        require(value <= type(uint160).max, "SafeCast: value doesn't fit in 160 bits");
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     *
     * _Available since v4.7._
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        require(value <= type(uint152).max, "SafeCast: value doesn't fit in 152 bits");
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     *
     * _Available since v4.7._
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        require(value <= type(uint144).max, "SafeCast: value doesn't fit in 144 bits");
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     *
     * _Available since v4.7._
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        require(value <= type(uint136).max, "SafeCast: value doesn't fit in 136 bits");
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v2.5._
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }

    /// @notice Cast a int128 to a uint128, revert on overflow or underflow
    /// @param x The int128 to be casted
    /// @return y The casted integer, now type uint128
    function toUint128(int128 x) internal pure returns (uint128 y) {
        if (x < 0) SafeCastOverflow.selector.revertWith();
        y = uint128(x);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     *
     * _Available since v4.7._
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        require(value <= type(uint120).max, "SafeCast: value doesn't fit in 120 bits");
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     *
     * _Available since v4.7._
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        require(value <= type(uint112).max, "SafeCast: value doesn't fit in 112 bits");
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     *
     * _Available since v4.7._
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        require(value <= type(uint104).max, "SafeCast: value doesn't fit in 104 bits");
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     *
     * _Available since v4.2._
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        require(value <= type(uint96).max, "SafeCast: value doesn't fit in 96 bits");
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     *
     * _Available since v4.7._
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        require(value <= type(uint88).max, "SafeCast: value doesn't fit in 88 bits");
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     *
     * _Available since v4.7._
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        require(value <= type(uint80).max, "SafeCast: value doesn't fit in 80 bits");
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     *
     * _Available since v4.7._
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        require(value <= type(uint72).max, "SafeCast: value doesn't fit in 72 bits");
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v2.5._
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 64 bits");
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     *
     * _Available since v4.7._
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        require(value <= type(uint56).max, "SafeCast: value doesn't fit in 56 bits");
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     *
     * _Available since v4.7._
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        require(value <= type(uint48).max, "SafeCast: value doesn't fit in 48 bits");
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     *
     * _Available since v4.7._
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        require(value <= type(uint40).max, "SafeCast: value doesn't fit in 40 bits");
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v2.5._
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "SafeCast: value doesn't fit in 32 bits");
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     *
     * _Available since v4.7._
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        require(value <= type(uint24).max, "SafeCast: value doesn't fit in 24 bits");
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v2.5._
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "SafeCast: value doesn't fit in 16 bits");
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     *
     * _Available since v2.5._
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        require(value <= type(uint8).max, "SafeCast: value doesn't fit in 8 bits");
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     *
     * _Available since v3.0._
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value must be positive");
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     *
     * _Available since v4.7._
     */
    function toInt248(int256 value) internal pure returns (int248) {
        require(value >= type(int248).min && value <= type(int248).max, "SafeCast: value doesn't fit in 248 bits");
        return int248(value);
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     *
     * _Available since v4.7._
     */
    function toInt240(int256 value) internal pure returns (int240) {
        require(value >= type(int240).min && value <= type(int240).max, "SafeCast: value doesn't fit in 240 bits");
        return int240(value);
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     *
     * _Available since v4.7._
     */
    function toInt232(int256 value) internal pure returns (int232) {
        require(value >= type(int232).min && value <= type(int232).max, "SafeCast: value doesn't fit in 232 bits");
        return int232(value);
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     *
     * _Available since v4.7._
     */
    function toInt224(int256 value) internal pure returns (int224) {
        require(value >= type(int224).min && value <= type(int224).max, "SafeCast: value doesn't fit in 224 bits");
        return int224(value);
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     *
     * _Available since v4.7._
     */
    function toInt216(int256 value) internal pure returns (int216) {
        require(value >= type(int216).min && value <= type(int216).max, "SafeCast: value doesn't fit in 216 bits");
        return int216(value);
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     *
     * _Available since v4.7._
     */
    function toInt208(int256 value) internal pure returns (int208) {
        require(value >= type(int208).min && value <= type(int208).max, "SafeCast: value doesn't fit in 208 bits");
        return int208(value);
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     *
     * _Available since v4.7._
     */
    function toInt200(int256 value) internal pure returns (int200) {
        require(value >= type(int200).min && value <= type(int200).max, "SafeCast: value doesn't fit in 200 bits");
        return int200(value);
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     *
     * _Available since v4.7._
     */
    function toInt192(int256 value) internal pure returns (int192) {
        require(value >= type(int192).min && value <= type(int192).max, "SafeCast: value doesn't fit in 192 bits");
        return int192(value);
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     *
     * _Available since v4.7._
     */
    function toInt184(int256 value) internal pure returns (int184) {
        require(value >= type(int184).min && value <= type(int184).max, "SafeCast: value doesn't fit in 184 bits");
        return int184(value);
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     *
     * _Available since v4.7._
     */
    function toInt176(int256 value) internal pure returns (int176) {
        require(value >= type(int176).min && value <= type(int176).max, "SafeCast: value doesn't fit in 176 bits");
        return int176(value);
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     *
     * _Available since v4.7._
     */
    function toInt168(int256 value) internal pure returns (int168) {
        require(value >= type(int168).min && value <= type(int168).max, "SafeCast: value doesn't fit in 168 bits");
        return int168(value);
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     *
     * _Available since v4.7._
     */
    function toInt160(int256 value) internal pure returns (int160) {
        require(value >= type(int160).min && value <= type(int160).max, "SafeCast: value doesn't fit in 160 bits");
        return int160(value);
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     *
     * _Available since v4.7._
     */
    function toInt152(int256 value) internal pure returns (int152) {
        require(value >= type(int152).min && value <= type(int152).max, "SafeCast: value doesn't fit in 152 bits");
        return int152(value);
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     *
     * _Available since v4.7._
     */
    function toInt144(int256 value) internal pure returns (int144) {
        require(value >= type(int144).min && value <= type(int144).max, "SafeCast: value doesn't fit in 144 bits");
        return int144(value);
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     *
     * _Available since v4.7._
     */
    function toInt136(int256 value) internal pure returns (int136) {
        require(value >= type(int136).min && value <= type(int136).max, "SafeCast: value doesn't fit in 136 bits");
        return int136(value);
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v3.1._
     */
    function toInt128(int256 value) internal pure returns (int128) {
        require(value >= type(int128).min && value <= type(int128).max, "SafeCast: value doesn't fit in 128 bits");
        return int128(value);
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     *
     * _Available since v4.7._
     */
    function toInt120(int256 value) internal pure returns (int120) {
        require(value >= type(int120).min && value <= type(int120).max, "SafeCast: value doesn't fit in 120 bits");
        return int120(value);
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     *
     * _Available since v4.7._
     */
    function toInt112(int256 value) internal pure returns (int112) {
        require(value >= type(int112).min && value <= type(int112).max, "SafeCast: value doesn't fit in 112 bits");
        return int112(value);
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     *
     * _Available since v4.7._
     */
    function toInt104(int256 value) internal pure returns (int104) {
        require(value >= type(int104).min && value <= type(int104).max, "SafeCast: value doesn't fit in 104 bits");
        return int104(value);
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     *
     * _Available since v4.7._
     */
    function toInt96(int256 value) internal pure returns (int96) {
        require(value >= type(int96).min && value <= type(int96).max, "SafeCast: value doesn't fit in 96 bits");
        return int96(value);
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     *
     * _Available since v4.7._
     */
    function toInt88(int256 value) internal pure returns (int88) {
        require(value >= type(int88).min && value <= type(int88).max, "SafeCast: value doesn't fit in 88 bits");
        return int88(value);
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     *
     * _Available since v4.7._
     */
    function toInt80(int256 value) internal pure returns (int80) {
        require(value >= type(int80).min && value <= type(int80).max, "SafeCast: value doesn't fit in 80 bits");
        return int80(value);
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     *
     * _Available since v4.7._
     */
    function toInt72(int256 value) internal pure returns (int72) {
        require(value >= type(int72).min && value <= type(int72).max, "SafeCast: value doesn't fit in 72 bits");
        return int72(value);
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v3.1._
     */
    function toInt64(int256 value) internal pure returns (int64) {
        require(value >= type(int64).min && value <= type(int64).max, "SafeCast: value doesn't fit in 64 bits");
        return int64(value);
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     *
     * _Available since v4.7._
     */
    function toInt56(int256 value) internal pure returns (int56) {
        require(value >= type(int56).min && value <= type(int56).max, "SafeCast: value doesn't fit in 56 bits");
        return int56(value);
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     *
     * _Available since v4.7._
     */
    function toInt48(int256 value) internal pure returns (int48) {
        require(value >= type(int48).min && value <= type(int48).max, "SafeCast: value doesn't fit in 48 bits");
        return int48(value);
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     *
     * _Available since v4.7._
     */
    function toInt40(int256 value) internal pure returns (int40) {
        require(value >= type(int40).min && value <= type(int40).max, "SafeCast: value doesn't fit in 40 bits");
        return int40(value);
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v3.1._
     */
    function toInt32(int256 value) internal pure returns (int32) {
        require(value >= type(int32).min && value <= type(int32).max, "SafeCast: value doesn't fit in 32 bits");
        return int32(value);
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     *
     * _Available since v4.7._
     */
    function toInt24(int256 value) internal pure returns (int24) {
        require(value >= type(int24).min && value <= type(int24).max, "SafeCast: value doesn't fit in 24 bits");
        return int24(value);
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v3.1._
     */
    function toInt16(int256 value) internal pure returns (int16) {
        require(value >= type(int16).min && value <= type(int16).max, "SafeCast: value doesn't fit in 16 bits");
        return int16(value);
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     *
     * _Available since v3.1._
     */
    function toInt8(int256 value) internal pure returns (int8) {
        require(value >= type(int8).min && value <= type(int8).max, "SafeCast: value doesn't fit in 8 bits");
        return int8(value);
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     *
     * _Available since v3.0._
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        require(value <= uint256(type(int256).max), "SafeCast: value doesn't fit in an int256");
        return int256(value);
    }
}


// File: contracts/8/interfaces/AbstractCommissionLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Abstract base contract with virtual functions
abstract contract AbstractCommissionLib {
    struct CommissionInfo {
        bool isFromTokenCommission; //0x00
        bool isToTokenCommission; //0x20
        address token; // 0x40
        uint256 toBCommission; // 0x60, 0 for no commission, 1 for no-toB commission, 2 for toB commission
        uint256 commissionLength; // 0x80
        uint256 commissionRate; // 0xa0
        address referrerAddress; // 0xc0
        uint256 commissionRate2; // 0xe0
        address referrerAddress2; // 0x100
        uint256 commissionRate3; // 0x120
        address referrerAddress3; // 0x140
        uint256 commissionRate4; // 0x160
        address referrerAddress4; // 0x180
        uint256 commissionRate5; // 0x1a0
        address referrerAddress5; // 0x1c0
        uint256 commissionRate6; // 0x1e0
        address referrerAddress6; // 0x200
        uint256 commissionRate7; // 0x220
        address referrerAddress7; // 0x240
        uint256 commissionRate8; // 0x260
        address referrerAddress8; // 0x280
    }

    struct TrimInfo {
        bool hasTrim; // 0x00
        uint256 trimRate; // 0x20
        address trimAddress; // 0x40
        uint256 toBTrim; // 0x60, 0 for no trim, 1 for no-toB trim, 2 for toB trim
        uint256 expectAmountOut; // 0x80
        uint256 chargeRate; // 0xa0
        address chargeAddress; // 0xc0
    }

    function _getCommissionAndTrimInfo()
        internal
        virtual
        returns (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo);

    // function _getBalanceOf(address token, address user)
    //     internal
    //     virtual
    //     returns (uint256);

    function _doCommissionFromToken(
        CommissionInfo memory commissionInfo,
        address payer,
        address receiver,
        uint256 inputAmount,
        bool hasTrim,
        address toToken
    ) internal virtual returns (address, uint256);

    function _doCommissionAndTrimToToken(
        CommissionInfo memory commissionInfo,
        address receiver,
        uint256 balanceBefore,
        address toToken,
        TrimInfo memory trimInfo
    ) internal virtual returns (uint256);

    function _validateCommissionInfo(
        CommissionInfo memory commissionInfo,
        address fromToken,
        address toToken,
        uint256 mode
    ) internal pure virtual;
}


// File: contracts/8/libraries/SafeERC20.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./SafeMath.sol";
import "./Address.sol";
import "./RevertReasonForwarder.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Permit.sol";
import "../interfaces/IDaiLikePermit.sol";

// File @1inch/solidity-utils/contracts/libraries/SafeERC20.sol@v2.1.1

library SafeERC20 {
    error SafeTransferFailed();
    error SafeTransferFromFailed();
    error ForceApproveFailed();
    error SafeIncreaseAllowanceFailed();
    error SafeDecreaseAllowanceFailed();
    error SafePermitBadLength();

    // Ensures method do not revert or return boolean `true`, admits call to non-smart-contract
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bytes4 selector = token.transferFrom.selector;
        bool success;
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            success := call(gas(), token, 0, data, 100, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
        if (!success) revert SafeTransferFromFailed();
    }

    // Ensures method do not revert or return boolean `true`, admits call to non-smart-contract
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        if (!_makeCall(token, token.transfer.selector, to, value)) {
            revert SafeTransferFailed();
        }
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        forceApprove(token, spender, value);
    }

    // If `approve(from, to, amount)` fails, try to `approve(from, to, 0)` before retry
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        if (!_makeCall(token, token.approve.selector, spender, value)) {
            if (!_makeCall(token, token.approve.selector, spender, 0) ||
                !_makeCall(token, token.approve.selector, spender, value))
            {
                revert ForceApproveFailed();
            }
        }
    }

    

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (value > type(uint256).max - allowance) revert SafeIncreaseAllowanceFailed();
        forceApprove(token, spender, allowance + value);
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (value > allowance) revert SafeDecreaseAllowanceFailed();
        forceApprove(token, spender, allowance - value);
    }

    function safePermit(IERC20 token, bytes calldata permit) internal {
        bool success;
        if (permit.length == 32 * 7) {
            success = _makeCalldataCall(token, IERC20Permit.permit.selector, permit);
        } else if (permit.length == 32 * 8) {
            success = _makeCalldataCall(token, IDaiLikePermit.permit.selector, permit);
        } else {
            revert SafePermitBadLength();
        }
        if (!success) RevertReasonForwarder.reRevert();
    }

    function _makeCall(IERC20 token, bytes4 selector, address to, uint256 amount) private returns(bool success) {
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), to)
            mstore(add(data, 0x24), amount)
            success := call(gas(), token, 0, data, 0x44, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }

    function _makeCalldataCall(IERC20 token, bytes4 selector, bytes calldata args) private returns(bool success) {
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            let len := add(4, args.length)
            let data := mload(0x40)

            mstore(data, selector)
            calldatacopy(add(data, 0x04), args.offset, args.length)
            success := call(gas(), token, 0, data, len, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 { success := gt(extcodesize(token), 0) }
                default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }
}




// File: contracts/8/interfaces/IAdapter.sol
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

interface IAdapter {
    function sellBase(
        address to,
        address pool,
        bytes memory data
    ) external;

    function sellQuote(
        address to,
        address pool,
        bytes memory data
    ) external;
}


// File: contracts/8/interfaces/IERC20.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);
}


// File: contracts/8/libraries/SafeMath.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SafeMath {
    uint256 constant WAD = 10**18;
    uint256 constant RAY = 10**27;

    function wad() public pure returns (uint256) {
        return WAD;
    }

    function ray() public pure returns (uint256) {
        return RAY;
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function sqrt(uint256 a) internal pure returns (uint256 b) {
        if (a > 3) {
            b = a;
            uint256 x = a / 2 + 1;
            while (x < b) {
                b = x;
                x = (a / x + x) / 2;
            }
        } else if (a != 0) {
            b = 1;
        }
    }

    function wmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mul(a, b) / WAD;
    }

    function wmulRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, b), WAD / 2) / WAD;
    }

    function rmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mul(a, b) / RAY;
    }

    function rmulRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, b), RAY / 2) / RAY;
    }

    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(mul(a, WAD), b);
    }

    function wdivRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, WAD), b / 2) / b;
    }

    function rdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(mul(a, RAY), b);
    }

    function rdivRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, RAY), b / 2) / b;
    }

    function wpow(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 result = WAD;
        while (n > 0) {
            if (n % 2 != 0) {
                result = wmul(result, x);
            }
            x = wmul(x, x);
            n /= 2;
        }
        return result;
    }

    function rpow(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 result = RAY;
        while (n > 0) {
            if (n % 2 != 0) {
                result = rmul(result, x);
            }
            x = rmul(x, x);
            n /= 2;
        }
        return result;
    }

    function divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 quotient = div(a, b);
        uint256 remainder = a - quotient * b;
        if (remainder > 0) {
            return quotient + 1;
        } else {
            return quotient;
        }
    }
}


// File: contracts/8/interfaces/IDexRouter.sol
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

interface IDexRouter {
    struct BaseRequest {
        uint256 fromToken;
        address toToken;
        uint256 fromTokenAmount;
        uint256 minReturnAmount;
        uint256 deadLine;
    }
    struct RouterPath {
        address[] mixAdapters;
        address[] assetTo;
        uint256[] rawData;
        bytes[] extraData;
        uint256 fromToken;
    }
    event OrderRecord(
        address fromToken,
        address toToken,
        address sender,
        uint256 fromAmount,
        uint256 returnAmount
    );
    event SwapOrderId(uint256 id);
}

// File: contracts/8/libraries/CustomRevert.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Library for reverting with custom errors efficiently
/// @notice Contains functions for reverting with custom errors with different argument types efficiently
/// @dev To use this library, declare `using CustomRevert for bytes4;` and replace `revert CustomError()` with
/// `CustomError.selector.revertWith()`
/// @dev The functions may tamper with the free memory pointer but it is fine since the call context is exited immediately
library CustomRevert {
    /// @dev ERC-7751 error for wrapping bubbled up reverts
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    /// @dev Reverts with the selector of a custom error in the scratch space
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 0x04)
        }
    }

    /// @dev Reverts with a custom error with an address argument in the scratch space
    function revertWith(bytes4 selector, address addr) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with an int24 argument in the scratch space
    function revertWith(bytes4 selector, int24 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, signextend(2, value))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with a uint160 argument in the scratch space
    function revertWith(bytes4 selector, uint160 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with two int24 arguments
    function revertWith(bytes4 selector, int24 value1, int24 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), signextend(2, value1))
            mstore(add(fmp, 0x24), signextend(2, value2))
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two uint160 arguments
    function revertWith(bytes4 selector, uint160 value1, uint160 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two address arguments
    function revertWith(bytes4 selector, address value1, address value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @notice bubble up the revert message returned by a call and revert with a wrapped ERC-7751 error
    /// @dev this method can be vulnerable to revert data bombs
    function bubbleUpAndRevertWith(
        address revertingContract,
        bytes4 revertingFunctionSelector,
        bytes4 additionalContext
    ) internal pure {
        bytes4 wrappedErrorSelector = WrappedError.selector;
        assembly ("memory-safe") {
            // Ensure the size of the revert data is a multiple of 32 bytes
            let encodedDataSize := mul(div(add(returndatasize(), 31), 32), 32)

            let fmp := mload(0x40)

            // Encode wrapped error selector, address, function selector, offset, additional context, size, revert reason
            mstore(fmp, wrappedErrorSelector)
            mstore(add(fmp, 0x04), and(revertingContract, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(
                add(fmp, 0x24),
                and(revertingFunctionSelector, 0xffffffff00000000000000000000000000000000000000000000000000000000)
            )
            // offset revert reason
            mstore(add(fmp, 0x44), 0x80)
            // offset additional context
            mstore(add(fmp, 0x64), add(0xa0, encodedDataSize))
            // size revert reason
            mstore(add(fmp, 0x84), returndatasize())
            // revert reason
            returndatacopy(add(fmp, 0xa4), 0, returndatasize())
            // size additional context
            mstore(add(fmp, add(0xa4, encodedDataSize)), 0x04)
            // additional context
            mstore(
                add(fmp, add(0xc4, encodedDataSize)),
                and(additionalContext, 0xffffffff00000000000000000000000000000000000000000000000000000000)
            )
            revert(fmp, add(0xe4, encodedDataSize))
        }
    }
}


// File: contracts/8/libraries/RevertReasonForwarder.sol
/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library RevertReasonForwarder {
    function reRevert() internal pure {
        // bubble up revert reason from latest external call
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, returndatasize())
            revert(ptr, returndatasize())
        }
    }
}

// File: contracts/8/interfaces/IERC20Permit.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on `{IERC20-approve}`, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over `owner`'s tokens,
     * given `owner`'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for `permit`, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}


// File: contracts/8/interfaces/IDaiLikePermit.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Interface for DAI-style permits
interface IDaiLikePermit {
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}


