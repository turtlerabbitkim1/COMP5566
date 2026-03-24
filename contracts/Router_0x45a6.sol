// File: src/Router.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IRouter} from "./interfaces/IRouter.sol";
import {RouterLib} from "./libraries/RouterLib.sol";
import {TokenLib} from "./libraries/TokenLib.sol";

/**
 * @title Router
 * @dev Router contract for swapping tokens using a predefined route.
 * The route must follow the PackedRoute format.
 */
contract Router is Ownable2Step, ReentrancyGuard, IRouter {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable WNATIVE;

    EnumerableSet.AddressSet private _trustedLogics;

    /**
     * @dev The allowances represent the maximum amount of tokens that the logic contract can spend on behalf of the sender.
     * It is always reseted at the end of the swap.
     * The key is calculated as keccak256(abi.encodePacked(token, sender, user)).
     */
    mapping(bytes32 key => uint256 allowance) private _allowances;

    /**
     * @dev Constructor for the Router contract.
     *
     * Requirements:
     * - The wnative address must be a contract with code.
     */
    constructor(address wnative, address initialOwner) Ownable(initialOwner) {
        if (address(wnative).code.length == 0) revert Router__InvalidWnative();

        WNATIVE = wnative;
    }

    /**
     * @dev Only allows native token to be received from unwrapping wnative.
     */
    receive() external payable {
        if (msg.sender != WNATIVE) revert Router__OnlyWnative();
    }

    /**
     * @dev Fallback function to validate and transfer tokens.
     */
    fallback() external {
        RouterLib.validateAndTransfer(_allowances);
    }

    /**
     * @dev Returns the logic contract address at the specified index.
     */
    function getTrustedLogicAt(uint256 index) external view override returns (address) {
        return _trustedLogics.at(index);
    }

    /**
     * @dev Returns the number of trusted logic contracts.
     */
    function getTrustedLogicLength() external view override returns (uint256) {
        return _trustedLogics.length();
    }

    /**
     * @dev Swaps tokens from the sender to the recipient using the exact input amount. It will use the specified logic contract.
     *
     * Emits a {SwapExactIn} event.
     *
     * Requirements:
     * - The logic contract must be a trusted logic contract.
     * - The recipient address must not be zero or the router address.
     * - The deadline must not have passed.
     * - The input token and output token must not be the same.
     * - If the amountIn is zero, the entire balance of the input token will be used and it must not be zero.
     * - The entire amountIn of the input token must be spent.
     * - The actual amount of tokenOut received must be greater than or equal to the amountOutMin.
     */
    function swapExactIn(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata route
    ) external payable override nonReentrant returns (uint256 totalIn, uint256 totalOut) {
        if (amountIn == 0) amountIn = tokenIn == address(0) ? msg.value : TokenLib.balanceOf(tokenIn, msg.sender);

        _verifyParameters(amountIn, amountOutMin, to, deadline);

        (totalIn, totalOut) = _swap(logic, tokenIn, tokenOut, amountIn, amountOutMin, msg.sender, to, route, true);

        emit SwapExactIn(msg.sender, to, tokenIn, tokenOut, totalIn, totalOut);
    }

    /**
     * @dev Swaps tokens from the sender to the recipient using the exact output amount. It will use the specified logic contract.
     *
     * Emits a {SwapExactOut} event.
     *
     * Requirements:
     * - The logic contract must be a trusted logic contract.
     * - The recipient address must not be zero or the router address.
     * - The deadline must not have passed.
     * - The input token and output token must not be the same.
     * - If the amountInMax is zero, the entire balance of the input token will be used and it must not be zero.
     * - The actual amount of tokenIn spent must be less than or equal to the amountInMax.
     * - The actual amount of tokenOut received must be greater than or equal to the amountOut.
     */
    function swapExactOut(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        address to,
        uint256 deadline,
        bytes calldata route
    ) external payable override nonReentrant returns (uint256 totalIn, uint256 totalOut) {
        _verifyParameters(amountInMax, amountOut, to, deadline);

        (totalIn, totalOut) = _swap(logic, tokenIn, tokenOut, amountInMax, amountOut, msg.sender, to, route, false);

        emit SwapExactOut(msg.sender, to, tokenIn, tokenOut, totalIn, totalOut);
    }

    /**
     * @dev Simulates the swap of tokens using multiple routes and the specified logic contract.
     * The simulation will revert with an array of amounts if the swap is valid.
     */
    function simulate(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bool exactIn,
        bytes[] calldata multiRoutes
    ) external payable override {
        uint256 length = multiRoutes.length;

        uint256[] memory amounts = new uint256[](length);
        for (uint256 i; i < length;) {
            (, bytes memory data) = address(this).delegatecall(
                abi.encodeWithSelector(
                    IRouter.simulateSingle.selector,
                    logic,
                    tokenIn,
                    tokenOut,
                    amountIn,
                    amountOut,
                    to,
                    exactIn,
                    multiRoutes[i++]
                )
            );

            if (bytes4(data) == IRouter.Router__SimulateSingle.selector) {
                assembly ("memory-safe") {
                    mstore(add(amounts, mul(i, 32)), mload(add(data, 36)))
                }
            } else {
                amounts[i - 1] = exactIn ? 0 : type(uint256).max;
            }
        }

        revert Router__Simulations(amounts);
    }

    /**
     * @dev Simulates the swap of tokens using a single route and the specified logic contract.
     * The simulation will revert with the total amount of tokenIn or tokenOut if the swap is valid.
     */
    function simulateSingle(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bool exactIn,
        bytes calldata route
    ) external payable override {
        _verifyParameters(amountIn, amountOut, to, block.timestamp);

        (uint256 totalIn, uint256 totalOut) =
            _swap(logic, tokenIn, tokenOut, amountIn, amountOut, msg.sender, to, route, exactIn);

        revert Router__SimulateSingle(exactIn ? totalOut : totalIn);
    }

    /**
     * @dev Updates the logic contract address.
     *
     * Emits a {RouterLogicUpdated} event.
     *
     * Requirements:
     * - The caller must be the owner.
     */
    function updateRouterLogic(address logic, bool add) external override onlyOwner {
        if (add) {
            if (!_trustedLogics.add(logic)) revert Router__LogicAlreadyAdded(logic);
        } else {
            if (!_trustedLogics.remove(logic)) revert Router__LogicNotFound(logic);
        }

        emit RouterLogicUpdated(logic, add);
    }

    /**
     * @dev Helper function to verify the input parameters of a swap.
     *
     * Requirements:
     * - The recipient address must not be zero or the router address.
     * - The deadline must not have passed.
     * - The amounts must not be zero.
     */
    function _verifyParameters(uint256 amountIn, uint256 amountOut, address to, uint256 deadline) internal view {
        if (to == address(0) || to == address(this)) revert Router__InvalidTo();
        if (block.timestamp > deadline) revert Router__DeadlineExceeded();
        if (amountIn == 0 || amountOut == 0) revert Router__ZeroAmount();
    }

    /**
     * @dev Helper function to verify the output of a swap.
     *
     * Requirements:
     * - The actual amount of tokenOut returned by the logic contract must be greater than the amountOutMin.
     * - The actual balance increase of the recipient must be greater than the amountOutMin.
     */
    function _verifySwap(address tokenOut, address to, uint256 balance, uint256 amountOutMin, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        if (amountOut < amountOutMin) revert Router__InsufficientOutputAmount(amountOut, amountOutMin);

        uint256 balanceAfter = TokenLib.universalBalanceOf(tokenOut, to);

        if (balanceAfter < balance + amountOutMin) {
            revert Router__InsufficientAmountReceived(balance, balanceAfter, amountOutMin);
        }

        unchecked {
            return balanceAfter - balance;
        }
    }

    /**
     * @dev Helper function to call the logic contract to swap tokens.
     * It will use the specified logic contract to swap the input token to the output token.
     * This function will wrap the input token if it is native and unwrap the output token if it is native.
     * It will also refund the sender if there is any excess amount of native token.
     * It will allow the logic contract to spend at most amountIn of the input token from the sender, and reset
     * the allowance after the swap, see {RouterLib.swap}.
     *
     * Requirements:
     * - The logic contract must be a trusted logic contract.
     * - If the swap is exactIn, the totalIn must be equal to the amountIn.
     * - If the swap is exactOut, the totalIn must be less than or equal to the amountIn.
     */
    function _swap(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address from,
        address to,
        bytes calldata route,
        bool exactIn
    ) internal returns (uint256 totalIn, uint256 totalOut) {
        if (!_trustedLogics.contains(logic)) revert Router__UntrustedLogic(logic);

        address recipient;
        (recipient, tokenOut) = tokenOut == address(0) ? (address(this), WNATIVE) : (to, tokenOut);

        if (tokenIn == address(0)) {
            tokenIn = WNATIVE;
            from = address(this);
            TokenLib.wrap(WNATIVE, amountIn);
        }

        if (tokenIn == tokenOut) revert Router__IdenticalTokens();

        uint256 balance = TokenLib.universalBalanceOf(tokenOut, recipient);

        (totalIn, totalOut) =
            RouterLib.swap(_allowances, tokenIn, tokenOut, amountIn, amountOut, from, recipient, route, exactIn, logic);

        if (recipient == address(this)) {
            totalOut = _verifySwap(tokenOut, recipient, balance, amountOut, totalOut);

            TokenLib.unwrap(WNATIVE, totalOut);
            TokenLib.transferNative(to, totalOut);
        } else {
            totalOut = _verifySwap(tokenOut, to, balance, amountOut, totalOut);
        }

        unchecked {
            uint256 refund;
            if (from == address(this)) {
                uint256 unwrap = amountIn - totalIn;
                if (unwrap > 0) TokenLib.unwrap(WNATIVE, unwrap);

                refund = msg.value + unwrap - amountIn;
            } else {
                refund = msg.value;
            }

            if (refund > 0) TokenLib.transferNative(msg.sender, refund);
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable2Step.sol)

pragma solidity ^0.8.20;

import {Ownable} from "./Ownable.sol";

/**
 * @dev Contract module which provides access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is specified at deployment time in the constructor for `Ownable`. This
 * can later be changed with {transferOwnership} and {acceptOwnership}.
 *
 * This module is used through inheritance. It will make available all functions
 * from parent (Ownable).
 */
abstract contract Ownable2Step is Ownable {
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Returns the address of the pending owner.
     */
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /**
     * @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`) and deletes any pending owner.
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    /**
     * @dev The new owner accepts the ownership transfer.
     */
    function acceptOwnership() public virtual {
        address sender = _msgSender();
        if (pendingOwner() != sender) {
            revert OwnableUnauthorizedAccount(sender);
        }
        _transferOwnership(sender);
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/structs/EnumerableSet.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableSet.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }
}


// File: src/interfaces/IRouter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRouter {
    error Router__DeadlineExceeded();
    error Router__InsufficientOutputAmount(uint256 outputAmount, uint256 minOutputAmount);
    error Router__InsufficientAmountReceived(uint256 balanceBefore, uint256 balanceAfter, uint256 amountOutMin);
    error Router__InvalidTo();
    error Router__ZeroAmount();
    error Router__OnlyWnative();
    error Router__InvalidWnative();
    error Router__IdenticalTokens();
    error Router__LogicAlreadyAdded(address routerLogic);
    error Router__LogicNotFound(address routerLogic);
    error Router__UntrustedLogic(address routerLogic);
    error Router__Simulations(uint256[] amounts);
    error Router__SimulateSingle(uint256 amount);

    event SwapExactIn(
        address indexed sender, address to, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );
    event SwapExactOut(
        address indexed sender, address to, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );
    event RouterLogicUpdated(address indexed routerLogic, bool added);

    function WNATIVE() external view returns (address);
    function getTrustedLogicAt(uint256 index) external view returns (address);
    function getTrustedLogicLength() external view returns (uint256);
    function updateRouterLogic(address routerLogic, bool added) external;
    function swapExactIn(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes memory route
    ) external payable returns (uint256, uint256);
    function swapExactOut(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        address to,
        uint256 deadline,
        bytes memory route
    ) external payable returns (uint256, uint256);
    function simulate(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bool exactIn,
        bytes[] calldata route
    ) external payable;
    function simulateSingle(
        address logic,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bool exactIn,
        bytes calldata route
    ) external payable;
}


// File: src/libraries/RouterLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TokenLib.sol";

/**
 * @title RouterLib
 * @dev Helper library for router operations, such as validateAndTransfer, transfer, and swap.
 * The router must implement a fallback function that uses `validateAndTransfer` to validate the allowance
 * and transfer the tokens and functions that uses `swap` to call the router logic to swap tokens.
 * The router logic must implement the `swapExactIn` and `swapExactOut` functions to swap tokens and
 * use the `transfer` function to transfer tokens from the router according to the route selected.
 */
library RouterLib {
    error RouterLib__ZeroAmount();
    error RouterLib__InsufficientAllowance(uint256 allowance, uint256 amount);

    /**
     * @dev Returns the slot for the allowance of a token for a sender from an address.
     */
    function getAllowanceSlot(
        mapping(bytes32 key => uint256) storage allowances,
        address token,
        address sender,
        address from
    ) internal pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0, shl(96, token))
            mstore(20, shl(96, sender))

            // Overwrite the last 8 bytes of the free memory pointer with zero,
            //which should always be zeros
            mstore(40, shl(96, from))

            let key := keccak256(0, 60)

            mstore(0, key)
            mstore(32, allowances.slot)

            s := keccak256(0, 64)
        }
    }

    /**
     * @dev Validates the allowance of a token for a sender from an address, and transfers the token.
     *
     * Requirements:
     * - The allowance must be greater than or equal to the amount.
     * - The amount must be greater than zero.
     * - If from is not the router, the token must have been approved for the router.
     */
    function validateAndTransfer(mapping(bytes32 key => uint256) storage allowances) internal {
        address token;
        address from;
        address to;
        uint256 amount;
        uint256 allowance;

        uint256 success;
        assembly ("memory-safe") {
            token := shr(96, calldataload(4))
            from := shr(96, calldataload(24))
            to := shr(96, calldataload(44))
            amount := calldataload(64)
        }

        bytes32 allowanceSlot = getAllowanceSlot(allowances, token, msg.sender, from);

        assembly ("memory-safe") {
            allowance := sload(allowanceSlot)

            if iszero(lt(allowance, amount)) {
                success := 1

                sstore(allowanceSlot, sub(allowance, amount))
            }
        }

        if (amount == 0) revert RouterLib__ZeroAmount(); // Also prevent calldata <= 64
        if (success == 0) revert RouterLib__InsufficientAllowance(allowance, amount);

        from == address(this) ? TokenLib.transfer(token, to, amount) : TokenLib.transferFrom(token, from, to, amount);
    }

    /**
     * @dev Calls the router to transfer tokens from an account to another account.
     *
     * Requirements:
     * - The call must succeed.
     * - The target contract must use `validateAndTransfer` inside its fallback function to validate the allowance
     *   and transfer the tokens accordingly.
     */
    function transfer(address router, address token, address from, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            let m0x40 := mload(0x40)

            mstore(0, shr(32, shl(96, token)))
            mstore(24, shl(96, from))
            mstore(44, shl(96, to))
            mstore(64, amount)

            if iszero(call(gas(), router, 0, 0, 96, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            mstore(0x40, m0x40)
        }
    }

    /**
     * @dev Swaps tokens using the router logic.
     * It will also set the allowance for the logic contract to spend the token from the sender and reset it
     * after the swap is done.
     *
     * Requirements:
     * - The logic contract must not be the zero address.
     * - The call must succeed.
     * - The logic contract must call this contract's fallback function to validate the allowance and transfer the tokens.
     */
    function swap(
        mapping(bytes32 key => uint256) storage allowances,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address from,
        address to,
        bytes calldata route,
        bool exactIn,
        address logic
    ) internal returns (uint256 totalIn, uint256 totalOut) {
        bytes32 allowanceSlot = getAllowanceSlot(allowances, tokenIn, logic, from);

        uint256 length = 256 + route.length; // 32 * 6 + 32 + 32 + route.length
        bytes memory data = new bytes(length);

        assembly ("memory-safe") {
            sstore(allowanceSlot, amountIn)

            switch exactIn
            // swapExactIn(tokenIn, tokenOut, amountIn, amountOut, from, to, route)
            // swapExactOut(tokenIn, tokenOut, amountOut, amountIn, from, to, route)
            case 1 { mstore(data, 0xbd084435) }
            default { mstore(data, 0xcb7e0007) }

            mstore(add(data, 32), tokenIn)
            mstore(add(data, 64), tokenOut)
            mstore(add(data, 96), amountIn)
            mstore(add(data, 128), amountOut)
            mstore(add(data, 160), from)
            mstore(add(data, 192), to)
            mstore(add(data, 224), 224) // 32 * 6 + 32
            mstore(add(data, 256), route.length)
            calldatacopy(add(data, 288), route.offset, route.length)

            if iszero(call(gas(), logic, 0, add(data, 28), add(length, 4), 0, 64)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            totalIn := mload(0)
            totalOut := mload(32)

            sstore(allowanceSlot, 0)
        }
    }
}


// File: src/libraries/TokenLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TokenLib
 * @dev Helper library for token operations, such as balanceOf, transfer, transferFrom, wrap, and unwrap.
 */
library TokenLib {
    error TokenLib__BalanceOfFailed();
    error TokenLib__WrapFailed();
    error TokenLib__UnwrapFailed();
    error TokenLib__NativeTransferFailed();
    error TokenLib__TransferFromFailed();
    error TokenLib__TransferFailed();

    /**
     * @dev Returns the balance of a token for an account.
     *
     * Requirements:
     * - The call must succeed.
     * - The target contract must return at least 32 bytes.
     */
    function balanceOf(address token, address account) internal view returns (uint256 amount) {
        uint256 success;
        uint256 returnDataSize;

        assembly ("memory-safe") {
            mstore(0, 0x70a08231) // balanceOf(address)
            mstore(32, account)

            success := staticcall(gas(), token, 28, 36, 0, 32)

            returnDataSize := returndatasize()

            amount := mload(0)
        }

        if (success == 0) _tryRevertWithReason();

        // If call failed, and it didn't already bubble up the revert reason, then the return data size must be 0,
        // which will revert here with a generic error message
        if (returnDataSize < 32) revert TokenLib__BalanceOfFailed();
    }

    /**
     * @dev Returns the balance of a token for an account, or the native balance of the account if the token is the native token.
     *
     * Requirements:
     * - The call must succeed (if the token is not the native token).
     * - The target contract must return at least 32 bytes (if the token is not the native token).
     */
    function universalBalanceOf(address token, address account) internal view returns (uint256 amount) {
        return token == address(0) ? account.balance : balanceOf(token, account);
    }

    /**
     * @dev Transfers native tokens to an account.
     *
     * Requirements:
     * - The call must succeed.
     */
    function transferNative(address to, uint256 amount) internal {
        uint256 success;

        assembly ("memory-safe") {
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        if (success == 0) {
            _tryRevertWithReason();
            revert TokenLib__NativeTransferFailed();
        }
    }

    /**
     * @dev Transfers tokens from an account to another account.
     * This function does not check if the target contract has code, this should be done before calling this function
     *
     * Requirements:
     * - The call must succeed.
     */
    function wrap(address wnative, uint256 amount) internal {
        uint256 success;

        assembly ("memory-safe") {
            mstore(0, 0xd0e30db0) // deposit()

            success := call(gas(), wnative, amount, 28, 4, 0, 0)
        }

        if (success == 0) {
            _tryRevertWithReason();
            revert TokenLib__WrapFailed();
        }
    }

    /**
     * @dev Transfers tokens from an account to another account.
     * This function does not check if the target contract has code, this should be done before calling this function
     *
     * Requirements:
     * - The call must succeed.
     */
    function unwrap(address wnative, uint256 amount) internal {
        uint256 success;

        assembly ("memory-safe") {
            mstore(0, 0x2e1a7d4d) // withdraw(uint256)
            mstore(32, amount)

            success := call(gas(), wnative, 0, 28, 36, 0, 0)
        }

        if (success == 0) {
            _tryRevertWithReason();
            revert TokenLib__UnwrapFailed();
        }
    }

    /**
     * @dev Transfers tokens from an account to another account.
     *
     * Requirements:
     * - The call must succeed
     * - The target contract must either return true or no value.
     * - The target contract must have code.
     */
    function transfer(address token, address to, uint256 amount) internal {
        uint256 success;
        uint256 returnSize;
        uint256 returnValue;

        assembly ("memory-safe") {
            let m0x40 := mload(0x40)

            mstore(0, 0xa9059cbb) // transfer(address,uint256)
            mstore(32, to)
            mstore(64, amount)

            success := call(gas(), token, 0, 28, 68, 0, 32)

            returnSize := returndatasize()
            returnValue := mload(0)

            mstore(0x40, m0x40)
        }

        if (success == 0) {
            _tryRevertWithReason();
            revert TokenLib__TransferFailed();
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) revert TokenLib__TransferFailed();
    }

    /**
     * @dev Transfers tokens from an account to another account.
     *
     * Requirements:
     * - The call must succeed.
     * - The target contract must either return true or no value.
     * - The target contract must have code.
     */
    function transferFrom(address token, address from, address to, uint256 amount) internal {
        uint256 success;
        uint256 returnSize;
        uint256 returnValue;

        assembly ("memory-safe") {
            let m0x40 := mload(0x40)
            let m0x60 := mload(0x60)

            mstore(0, 0x23b872dd) // transferFrom(address,address,uint256)
            mstore(32, from)
            mstore(64, to)
            mstore(96, amount)

            success := call(gas(), token, 0, 28, 100, 0, 32)

            returnSize := returndatasize()
            returnValue := mload(0)

            mstore(0x40, m0x40)
            mstore(0x60, m0x60)
        }

        if (success == 0) {
            _tryRevertWithReason();
            revert TokenLib__TransferFromFailed();
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) revert TokenLib__TransferFromFailed();
    }

    /**
     * @dev Tries to bubble up the revert reason.
     * This function needs to be called only if the call has failed, and will revert if there is a revert reason.
     * This function might no revert if there is no revert reason, always use it in conjunction with a revert.
     */
    function _tryRevertWithReason() private pure {
        assembly ("memory-safe") {
            if returndatasize() {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}


// File: lib/openzeppelin-contracts/contracts/access/Ownable.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;

import {Context} from "../utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


// File: lib/openzeppelin-contracts/contracts/utils/Context.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}


