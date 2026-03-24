// File: @gnosis.pm/safe-contracts/contracts/common/Enum.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/// @title Enum - Collection of enums
/// @author Richard Meissner - <richard@gnosis.pm>
contract Enum {
    enum Operation {Call, DelegateCall}
}


// File: @gnosis.pm/zodiac/contracts/core/Modifier.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {ExecutionTracker} from "../signature/ExecutionTracker.sol";
import {IAvatar} from "../interfaces/IAvatar.sol";
import {Module} from "./Module.sol";
import {SignatureChecker} from "../signature/SignatureChecker.sol";

/// @title Modifier Interface - A contract that sits between a Module and an Avatar and enforce some additional logic.
abstract contract Modifier is
  Module,
  ExecutionTracker,
  SignatureChecker,
  IAvatar
{
  address internal constant SENTINEL_MODULES = address(0x1);
  /// Mapping of modules.
  mapping(address => address) internal modules;

  /// `sender` is not an authorized module.
  /// @param sender The address of the sender.
  error NotAuthorized(address sender);

  /// `module` is invalid.
  error InvalidModule(address module);

  /// `pageSize` is invalid.
  error InvalidPageSize();

  /// `module` is already disabled.
  error AlreadyDisabledModule(address module);

  /// `module` is already enabled.
  error AlreadyEnabledModule(address module);

  /// @dev `setModules()` was already called.
  error SetupModulesAlreadyCalled();

  /*
    --------------------------------------------------
    You must override both of the following virtual functions,
    execTransactionFromModule() and execTransactionFromModuleReturnData().
    It is recommended that implementations of both functions make use the 
    onlyModule modifier.
    */

  /// @dev Passes a transaction to the modifier.
  /// @notice Can only be called by enabled modules.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction.
  function execTransactionFromModule(
    address to,
    uint256 value,
    bytes calldata data,
    Enum.Operation operation
  ) public virtual returns (bool success);

  /// @dev Passes a transaction to the modifier, expects return data.
  /// @notice Can only be called by enabled modules.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction.
  function execTransactionFromModuleReturnData(
    address to,
    uint256 value,
    bytes calldata data,
    Enum.Operation operation
  ) public virtual returns (bool success, bytes memory returnData);

  /*
    --------------------------------------------------
    */

  modifier moduleOnly() {
    if (modules[msg.sender] == address(0)) {
      (bytes32 hash, address signer) = moduleTxSignedBy();

      // is the signer a module?
      if (modules[signer] == address(0)) {
        revert NotAuthorized(msg.sender);
      }

      // is the provided signature fresh?
      if (consumed[signer][hash]) {
        revert HashAlreadyConsumed(hash);
      }

      consumed[signer][hash] = true;
      emit HashExecuted(hash);
    }

    _;
  }

  function sentOrSignedByModule() internal view returns (address) {
    if (modules[msg.sender] != address(0)) {
      return msg.sender;
    }

    (, address signer) = moduleTxSignedBy();
    if (modules[signer] != address(0)) {
      return signer;
    }

    return address(0);
  }

  /// @dev Disables a module on the modifier.
  /// @notice This can only be called by the owner.
  /// @param prevModule Module that pointed to the module to be removed in the linked list.
  /// @param module Module to be removed.
  function disableModule(
    address prevModule,
    address module
  ) public override onlyOwner {
    if (module == address(0) || module == SENTINEL_MODULES)
      revert InvalidModule(module);
    if (modules[prevModule] != module) revert AlreadyDisabledModule(module);
    modules[prevModule] = modules[module];
    modules[module] = address(0);
    emit DisabledModule(module);
  }

  /// @dev Enables a module that can add transactions to the queue
  /// @param module Address of the module to be enabled
  /// @notice This can only be called by the owner
  function enableModule(address module) public override onlyOwner {
    if (module == address(0) || module == SENTINEL_MODULES)
      revert InvalidModule(module);
    if (modules[module] != address(0)) revert AlreadyEnabledModule(module);
    modules[module] = modules[SENTINEL_MODULES];
    modules[SENTINEL_MODULES] = module;
    emit EnabledModule(module);
  }

  /// @dev Returns if an module is enabled
  /// @return True if the module is enabled
  function isModuleEnabled(
    address _module
  ) public view override returns (bool) {
    return SENTINEL_MODULES != _module && modules[_module] != address(0);
  }

  /// @dev Returns array of modules.
  ///      If all entries fit into a single page, the next pointer will be 0x1.
  ///      If another page is present, next will be the last element of the returned array.
  /// @param start Start of the page. Has to be a module or start pointer (0x1 address)
  /// @param pageSize Maximum number of modules that should be returned. Has to be > 0
  /// @return array Array of modules.
  /// @return next Start of the next page.
  function getModulesPaginated(
    address start,
    uint256 pageSize
  ) external view override returns (address[] memory array, address next) {
    if (start != SENTINEL_MODULES && !isModuleEnabled(start)) {
      revert InvalidModule(start);
    }
    if (pageSize == 0) {
      revert InvalidPageSize();
    }

    // Init array with max page size
    array = new address[](pageSize);

    // Populate return array
    uint256 moduleCount = 0;
    next = modules[start];
    while (
      next != address(0) && next != SENTINEL_MODULES && moduleCount < pageSize
    ) {
      array[moduleCount] = next;
      next = modules[next];
      moduleCount++;
    }

    // Because of the argument validation we can assume that
    // the `currentModule` will always be either a module address
    // or sentinel address (aka the end). If we haven't reached the end
    // inside the loop, we need to set the next pointer to the last element
    // because it skipped over to the next module which is neither included
    // in the current page nor won't be included in the next one
    // if you pass it as a start.
    if (next != SENTINEL_MODULES) {
      next = array[moduleCount - 1];
    }
    // Set correct size of returned array
    // solhint-disable-next-line no-inline-assembly
    assembly {
      mstore(array, moduleCount)
    }
  }

  /// @dev Initializes the modules linked list.
  /// @notice Should be called as part of the `setUp` / initializing function and can only be called once.
  function setupModules() internal {
    if (modules[SENTINEL_MODULES] != address(0))
      revert SetupModulesAlreadyCalled();
    modules[SENTINEL_MODULES] = SENTINEL_MODULES;
  }
}


// File: @gnosis.pm/zodiac/contracts/core/Module.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {FactoryFriendly} from "../factory/FactoryFriendly.sol";
import {IAvatar} from "../interfaces/IAvatar.sol";

/// @title Module Interface - A contract that can pass messages to a Module Manager contract if enabled by that contract.
abstract contract Module is FactoryFriendly {
  /// @dev Address that will ultimately execute function calls.
  address public avatar;
  /// @dev Address that this module will pass transactions to.
  address public target;

  /// @dev Emitted each time the avatar is set.
  event AvatarSet(address indexed previousAvatar, address indexed newAvatar);
  /// @dev Emitted each time the Target is set.
  event TargetSet(address indexed previousTarget, address indexed newTarget);

  /// @dev Sets the avatar to a new avatar (`newAvatar`).
  /// @notice Can only be called by the current owner.
  function setAvatar(address _avatar) public onlyOwner {
    address previousAvatar = avatar;
    avatar = _avatar;
    emit AvatarSet(previousAvatar, _avatar);
  }

  /// @dev Sets the target to a new target (`newTarget`).
  /// @notice Can only be called by the current owner.
  function setTarget(address _target) public onlyOwner {
    address previousTarget = target;
    target = _target;
    emit TargetSet(previousTarget, _target);
  }

  /// @dev Passes a transaction to be executed by the avatar.
  /// @notice Can only be called by this contract.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
  function exec(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation
  ) internal virtual returns (bool success) {
    return
      IAvatar(target).execTransactionFromModule(to, value, data, operation);
  }

  /// @dev Passes a transaction to be executed by the target and returns data.
  /// @notice Can only be called by this contract.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
  function execAndReturnData(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation
  ) internal virtual returns (bool success, bytes memory returnData) {
    return
      IAvatar(target).execTransactionFromModuleReturnData(
        to,
        value,
        data,
        operation
      );
  }
}


// File: @gnosis.pm/zodiac/contracts/factory/FactoryFriendly.sol
// SPDX-License-Identifier: LGPL-3.0-only

/// @title Zodiac FactoryFriendly - A contract that allows other contracts to be initializable and pass bytes as arguments to define contract state
pragma solidity >=0.7.0 <0.9.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract FactoryFriendly is OwnableUpgradeable {
  function setUp(bytes memory initializeParams) public virtual;
}


// File: @gnosis.pm/zodiac/contracts/interfaces/IAvatar.sol
// SPDX-License-Identifier: LGPL-3.0-only

/// @title Zodiac Avatar - A contract that manages modules that can execute transactions via this contract.
pragma solidity >=0.7.0 <0.9.0;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

interface IAvatar {
  event EnabledModule(address module);
  event DisabledModule(address module);
  event ExecutionFromModuleSuccess(address indexed module);
  event ExecutionFromModuleFailure(address indexed module);

  /// @dev Enables a module on the avatar.
  /// @notice Can only be called by the avatar.
  /// @notice Modules should be stored as a linked list.
  /// @notice Must emit EnabledModule(address module) if successful.
  /// @param module Module to be enabled.
  function enableModule(address module) external;

  /// @dev Disables a module on the avatar.
  /// @notice Can only be called by the avatar.
  /// @notice Must emit DisabledModule(address module) if successful.
  /// @param prevModule Address that pointed to the module to be removed in the linked list
  /// @param module Module to be removed.
  function disableModule(address prevModule, address module) external;

  /// @dev Allows a Module to execute a transaction.
  /// @notice Can only be called by an enabled module.
  /// @notice Must emit ExecutionFromModuleSuccess(address module) if successful.
  /// @notice Must emit ExecutionFromModuleFailure(address module) if unsuccessful.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
  function execTransactionFromModule(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation
  ) external returns (bool success);

  /// @dev Allows a Module to execute a transaction and return data
  /// @notice Can only be called by an enabled module.
  /// @notice Must emit ExecutionFromModuleSuccess(address module) if successful.
  /// @notice Must emit ExecutionFromModuleFailure(address module) if unsuccessful.
  /// @param to Destination address of module transaction.
  /// @param value Ether value of module transaction.
  /// @param data Data payload of module transaction.
  /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
  function execTransactionFromModuleReturnData(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation
  ) external returns (bool success, bytes memory returnData);

  /// @dev Returns if an module is enabled
  /// @return True if the module is enabled
  function isModuleEnabled(address module) external view returns (bool);

  /// @dev Returns array of modules.
  /// @param start Start of the page.
  /// @param pageSize Maximum number of modules that should be returned.
  /// @return array Array of modules.
  /// @return next Start of the next page.
  function getModulesPaginated(
    address start,
    uint256 pageSize
  ) external view returns (address[] memory array, address next);
}


// File: @gnosis.pm/zodiac/contracts/signature/ExecutionTracker.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.0 <0.9.0;

/// @title ExecutionTracker - A contract that keeps track of executed and invalidated hashes
contract ExecutionTracker {
  error HashAlreadyConsumed(bytes32);

  event HashExecuted(bytes32);
  event HashInvalidated(bytes32);

  mapping(address => mapping(bytes32 => bool)) public consumed;

  function invalidate(bytes32 hash) external {
    consumed[msg.sender][hash] = true;
    emit HashInvalidated(hash);
  }
}


// File: @gnosis.pm/zodiac/contracts/signature/IERC1271.sol
// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity >=0.7.0 <0.9.0;

interface IERC1271 {
  /**
   * @notice EIP1271 method to validate a signature.
   * @param hash Hash of the data signed on the behalf of address(this).
   * @param signature Signature byte array associated with _data.
   *
   * MUST return the bytes4 magic value 0x1626ba7e when function passes.
   * MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5)
   * MUST allow external calls
   */
  function isValidSignature(
    bytes32 hash,
    bytes memory signature
  ) external view returns (bytes4);
}


// File: @gnosis.pm/zodiac/contracts/signature/SignatureChecker.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.0 <0.9.0;

import {IERC1271} from "./IERC1271.sol";

/// @title SignatureChecker - A contract that retrieves and validates signatures appended to transaction calldata.
/// @dev currently supports eip-712 and eip-1271 signatures
abstract contract SignatureChecker {
  /**
   * @notice Searches for a signature, validates it, and returns the signer's address.
   * @dev When signature not found or invalid, zero address is returned
   * @return The address of the signer.
   */
  function moduleTxSignedBy() internal view returns (bytes32, address) {
    bytes calldata data = msg.data;

    /*
     * The idea is to extend `onlyModule` and provide signature checking
     * without code changes to inheriting contracts (Modifiers).
     *
     * Since it's a generic mechanism, there is no way to conclusively
     * identify the trailing bytes as a signature. We simply slice those
     * and recover signer.
     *
     * As a result, we impose a minimum calldata length equal to a function
     * selector plus salt, plus a signature (i.e., 4 + 32 + 65 bytes), any
     * shorter and calldata it guaranteed to not contain a signature.
     */
    if (data.length < 4 + 32 + 65) {
      return (bytes32(0), address(0));
    }

    (uint8 v, bytes32 r, bytes32 s) = _splitSignature(data);

    uint256 end = data.length - (32 + 65);
    bytes32 salt = bytes32(data[end:]);

    /*
     * When handling contract signatures:
     *  v - is zero
     *  r - contains the signer
     *  s - contains the offset within calldata where the signer specific
     *      signature is located
     *
     * We detect contract signatures by checking:
     *  1- `v` is zero
     *  2- `s` points within the buffer, is after selector, is before
     *      salt and delimits a non-zero length buffer
     */
    if (v == 0) {
      uint256 start = uint256(s);
      if (start < 4 || start > end) {
        return (bytes32(0), address(0));
      }
      address signer = address(uint160(uint256(r)));

      bytes32 hash = moduleTxHash(data[:start], salt);
      return
        _isValidContractSignature(signer, hash, data[start:end])
          ? (hash, signer)
          : (bytes32(0), address(0));
    } else {
      bytes32 hash = moduleTxHash(data[:end], salt);
      return (hash, ecrecover(hash, v, r, s));
    }
  }

  /**
   * @notice Hashes the transaction EIP-712 data structure.
   * @dev The produced hash is intended to be signed.
   * @param data The current transaction's calldata.
   * @param salt The salt value.
   * @return The 32-byte hash that is to be signed.
   */
  function moduleTxHash(
    bytes calldata data,
    bytes32 salt
  ) public view returns (bytes32) {
    bytes32 domainSeparator = keccak256(
      abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, this)
    );
    bytes memory moduleTxData = abi.encodePacked(
      bytes1(0x19),
      bytes1(0x01),
      domainSeparator,
      keccak256(abi.encode(MODULE_TX_TYPEHASH, keccak256(data), salt))
    );
    return keccak256(moduleTxData);
  }

  /**
   * @dev Extracts signature from calldata, and divides it into `uint8 v, bytes32 r, bytes32 s`.
   * @param data The current transaction's calldata.
   * @return v The ECDSA v value
   * @return r The ECDSA r value
   * @return s The ECDSA s value
   */
  function _splitSignature(
    bytes calldata data
  ) private pure returns (uint8 v, bytes32 r, bytes32 s) {
    v = uint8(bytes1(data[data.length - 1:]));
    r = bytes32(data[data.length - 65:]);
    s = bytes32(data[data.length - 33:]);
  }

  /**
   * @dev Calls the signer contract, and validates the contract signature.
   * @param signer The address of the signer contract.
   * @param hash Hash of the data signed
   * @param signature The contract signature.
   * @return result Indicates whether the signature is valid.
   */
  function _isValidContractSignature(
    address signer,
    bytes32 hash,
    bytes calldata signature
  ) internal view returns (bool result) {
    uint256 size;
    // eslint-disable-line no-inline-assembly
    assembly {
      size := extcodesize(signer)
    }
    if (size == 0) {
      return false;
    }

    (, bytes memory returnData) = signer.staticcall(
      abi.encodeWithSelector(
        IERC1271.isValidSignature.selector,
        hash,
        signature
      )
    );

    return bytes4(returnData) == EIP1271_MAGIC_VALUE;
  }

  // keccak256(
  //     "EIP712Domain(uint256 chainId,address verifyingContract)"
  // );
  bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
    0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

  // keccak256(
  //     "ModuleTx(bytes data,bytes32 salt)"
  // );
  bytes32 private constant MODULE_TX_TYPEHASH =
    0x2939aeeda3ca260200c9f7b436b19e13207547ccc65cfedc857751c5ea6d91d4;

  // bytes4(keccak256(
  //     "isValidSignature(bytes32,bytes)"
  // ));
  bytes4 private constant EIP1271_MAGIC_VALUE = 0x1626ba7e;
}


// File: @openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;

import {ContextUpgradeable} from "../utils/ContextUpgradeable.sol";
import {Initializable} from "../proxy/utils/Initializable.sol";

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
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.Ownable
    struct OwnableStorage {
        address _owner;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OwnableStorageLocation = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    function _getOwnableStorage() private pure returns (OwnableStorage storage $) {
        assembly {
            $.slot := OwnableStorageLocation
        }
    }

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
    function __Ownable_init(address initialOwner) internal onlyInitializing {
        __Ownable_init_unchained(initialOwner);
    }

    function __Ownable_init_unchained(address initialOwner) internal onlyInitializing {
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
        OwnableStorage storage $ = _getOwnableStorage();
        return $._owner;
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
        OwnableStorage storage $ = _getOwnableStorage();
        address oldOwner = $._owner;
        $._owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


// File: @openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (proxy/utils/Initializable.sol)

pragma solidity ^0.8.20;

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```solidity
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 *
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Storage of the initializable contract.
     *
     * It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions
     * when using with upgradeable contracts.
     *
     * @custom:storage-location erc7201:openzeppelin.storage.Initializable
     */
    struct InitializableStorage {
        /**
         * @dev Indicates that the contract has been initialized.
         */
        uint64 _initialized;
        /**
         * @dev Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /**
     * @dev The contract is already initialized.
     */
    error InvalidInitialization();

    /**
     * @dev The contract is not initializing.
     */
    error NotInitializing();

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint64 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts.
     *
     * Similar to `reinitializer(1)`, except that in the context of a constructor an `initializer` may be invoked any
     * number of times. This behavior in the constructor can be useful during testing and is not expected to be used in
     * production.
     *
     * Emits an {Initialized} event.
     */
    modifier initializer() {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        // Cache values to avoid duplicated sloads
        bool isTopLevelCall = !$._initializing;
        uint64 initialized = $._initialized;

        // Allowed calls:
        // - initialSetup: the contract is not in the initializing state and no previous version was
        //                 initialized
        // - construction: the contract is initialized at version 1 (no reininitialization) and the
        //                 current contract is just being deployed
        bool initialSetup = initialized == 0 && isTopLevelCall;
        bool construction = initialized == 1 && address(this).code.length == 0;

        if (!initialSetup && !construction) {
            revert InvalidInitialization();
        }
        $._initialized = 1;
        if (isTopLevelCall) {
            $._initializing = true;
        }
        _;
        if (isTopLevelCall) {
            $._initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * A reinitializer may be used after the original initialization step. This is essential to configure modules that
     * are added through upgrades and that require initialization.
     *
     * When `version` is 1, this modifier is similar to `initializer`, except that functions marked with `reinitializer`
     * cannot be nested. If one is invoked in the context of another, execution will revert.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     *
     * WARNING: Setting the version to 2**64 - 1 will prevent any future reinitialization.
     *
     * Emits an {Initialized} event.
     */
    modifier reinitializer(uint64 version) {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing || $._initialized >= version) {
            revert InvalidInitialization();
        }
        $._initialized = version;
        $._initializing = true;
        _;
        $._initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    /**
     * @dev Reverts if the contract is not in an initializing state. See {onlyInitializing}.
     */
    function _checkInitializing() internal view virtual {
        if (!_isInitializing()) {
            revert NotInitializing();
        }
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     *
     * Emits an {Initialized} event the first time it is successfully executed.
     */
    function _disableInitializers() internal virtual {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing) {
            revert InvalidInitialization();
        }
        if ($._initialized != type(uint64).max) {
            $._initialized = type(uint64).max;
            emit Initialized(type(uint64).max);
        }
    }

    /**
     * @dev Returns the highest version that has been initialized. See {reinitializer}.
     */
    function _getInitializedVersion() internal view returns (uint64) {
        return _getInitializableStorage()._initialized;
    }

    /**
     * @dev Returns `true` if the contract is currently initializing. See {onlyInitializing}.
     */
    function _isInitializing() internal view returns (bool) {
        return _getInitializableStorage()._initializing;
    }

    /**
     * @dev Returns a pointer to the storage namespace.
     */
    // solhint-disable-next-line var-name-mixedcase
    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE
        }
    }
}


// File: @openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/Context.sol)

pragma solidity ^0.8.20;
import {Initializable} from "../proxy/utils/Initializable.sol";

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
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal onlyInitializing {
    }

    function __Context_init_unchained() internal onlyInitializing {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}


// File: contracts/adapters/Types.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

interface IMultiSend {
    function multiSend(bytes memory transactions) external payable;
}

struct UnwrappedTransaction {
    Enum.Operation operation;
    address to;
    uint256 value;
    // We wanna deal in calldata slices. We return location, let invoker slice
    uint256 dataLocation;
    uint256 dataSize;
}

interface ITransactionUnwrapper {
    function unwrap(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) external view returns (UnwrappedTransaction[] memory result);
}

interface ICustomCondition {
    function check(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 location,
        uint256 size,
        bytes12 extra
    ) external view returns (bool success, bytes32 reason);
}


// File: contracts/AllowanceTracker.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./Core.sol";

/**
 * @title AllowanceTracker - a component of the Zodiac Roles Mod that is
 * responsible for loading and calculating allowance balances. Persists
 * consumptions back to storage.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 * @author Jan-Felix Schwarz  - <jan-felix.schwarz@gnosis.io>
 */
abstract contract AllowanceTracker is Core {
    event ConsumeAllowance(
        bytes32 allowanceKey,
        uint128 consumed,
        uint128 newBalance
    );

    function _accruedAllowance(
        Allowance memory allowance,
        uint64 blockTimestamp
    ) internal pure override returns (uint128 balance, uint64 timestamp) {
        if (
            allowance.period == 0 ||
            blockTimestamp < (allowance.timestamp + allowance.period)
        ) {
            return (allowance.balance, allowance.timestamp);
        }

        uint64 elapsedIntervals = (blockTimestamp - allowance.timestamp) /
            allowance.period;

        if (allowance.balance < allowance.maxRefill) {
            balance = allowance.balance + allowance.refill * elapsedIntervals;

            balance = balance < allowance.maxRefill
                ? balance
                : allowance.maxRefill;
        } else {
            balance = allowance.balance;
        }

        timestamp = allowance.timestamp + elapsedIntervals * allowance.period;
    }

    /**
     * @dev Flushes the consumption of allowances back into storage, before
     * execution. This flush is not final
     * @param consumptions The array of consumption structs containing
     * information about allowances and consumed amounts.
     */
    function _flushPrepare(Consumption[] memory consumptions) internal {
        uint256 count = consumptions.length;

        for (uint256 i; i < count; ) {
            Consumption memory consumption = consumptions[i];

            bytes32 key = consumption.allowanceKey;
            uint128 consumed = consumption.consumed;

            // Retrieve the allowance and calculate its current updated balance
            // and next refill timestamp.
            Allowance storage allowance = allowances[key];
            (uint128 balance, uint64 timestamp) = _accruedAllowance(
                allowance,
                uint64(block.timestamp)
            );

            assert(balance == consumption.balance);
            assert(consumed <= balance);
            // Flush
            allowance.balance = balance - consumed;
            allowance.timestamp = timestamp;

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Finalizes or reverts the flush of allowances, after transaction
     * execution
     * @param consumptions The array of consumption structs containing
     * information about allowances and consumed amounts.
     * @param success a boolean that indicates whether transaction execution
     * was successful
     */
    function _flushCommit(
        Consumption[] memory consumptions,
        bool success
    ) internal {
        uint256 count = consumptions.length;
        for (uint256 i; i < count; ) {
            Consumption memory consumption = consumptions[i];
            bytes32 key = consumption.allowanceKey;
            if (success) {
                emit ConsumeAllowance(
                    key,
                    consumption.consumed,
                    consumption.balance - consumption.consumed
                );
            } else {
                allowances[key].balance = consumption.balance;
            }
            unchecked {
                ++i;
            }
        }
    }
}


// File: contracts/Consumptions.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./Types.sol";

/**
 * @title Consumptions - a library that provides helper functions for dealing
 * with collection of Consumptions.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
library Consumptions {
    function clone(
        Consumption[] memory consumptions
    ) internal pure returns (Consumption[] memory result) {
        uint256 length = consumptions.length;

        result = new Consumption[](length);
        for (uint256 i; i < length; ) {
            result[i].allowanceKey = consumptions[i].allowanceKey;
            result[i].balance = consumptions[i].balance;
            result[i].consumed = consumptions[i].consumed;

            unchecked {
                ++i;
            }
        }
    }

    function find(
        Consumption[] memory consumptions,
        bytes32 key
    ) internal pure returns (uint256, bool) {
        uint256 length = consumptions.length;

        for (uint256 i; i < length; ) {
            if (consumptions[i].allowanceKey == key) {
                return (i, true);
            }

            unchecked {
                ++i;
            }
        }

        return (0, false);
    }

    function merge(
        Consumption[] memory c1,
        Consumption[] memory c2
    ) internal pure returns (Consumption[] memory result) {
        if (c1.length == 0) return c2;
        if (c2.length == 0) return c1;

        result = new Consumption[](c1.length + c2.length);

        uint256 length = c1.length;

        for (uint256 i; i < length; ) {
            result[i].allowanceKey = c1[i].allowanceKey;
            result[i].balance = c1[i].balance;
            result[i].consumed = c1[i].consumed;

            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < c2.length; ) {
            (uint256 index, bool found) = find(c1, c2[i].allowanceKey);
            if (found) {
                result[index].consumed += c2[i].consumed;
            } else {
                result[length].allowanceKey = c2[i].allowanceKey;
                result[length].balance = c2[i].balance;
                result[length].consumed = c2[i].consumed;
                length++;
            }

            unchecked {
                ++i;
            }
        }

        if (length < result.length) {
            assembly {
                mstore(result, length)
            }
        }
    }
}


// File: contracts/Core.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "@gnosis.pm/zodiac/contracts/core/Modifier.sol";
import "./Types.sol";

/**
 * @title Core is the base contract for the Zodiac Roles Mod, which defines
 * the common abstract connection points between Builder, Loader, and Checker.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
abstract contract Core is Modifier {
    mapping(bytes32 => Role) internal roles;
    mapping(bytes32 => Allowance) public allowances;

    function _store(
        Role storage role,
        bytes32 key,
        ConditionFlat[] memory conditions,
        ExecutionOptions options
    ) internal virtual;

    function _load(
        Role storage role,
        bytes32 key
    ) internal view virtual returns (Condition memory, Consumption[] memory);

    function _accruedAllowance(
        Allowance memory allowance,
        uint64 blockTimestamp
    ) internal pure virtual returns (uint128 balance, uint64 timestamp);

    function _key(
        address targetAddress,
        bytes4 selector
    ) internal pure returns (bytes32) {
        /*
         * Unoptimized version:
         * bytes32(abi.encodePacked(targetAddress, selector))
         */
        return bytes32(bytes20(targetAddress)) | (bytes32(selector) >> 160);
    }
}


// File: contracts/Decoder.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./Topology.sol";

/**
 * @title Decoder - a library that discovers parameter locations in calldata
 * from a list of conditions.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
library Decoder {
    error CalldataOutOfBounds();

    /**
     * @dev Maps the location and size of parameters in the encoded transaction data.
     * @param data The encoded transaction data.
     * @param condition The condition of the parameters.
     * @return result The mapped location and size of parameters in the encoded transaction data.
     */
    function inspect(
        bytes calldata data,
        Condition memory condition
    ) internal pure returns (ParameterPayload memory result) {
        /*
         * In the parameter encoding area, there is a region called the head
         * that is divided into 32-byte chunks. Each parameter has its own
         * corresponding chunk in the head region:
         * - Static parameters are encoded inline.
         * - Dynamic parameters have an offset to the tail, which is the start
         *   of the actual encoding for the dynamic parameter. Note that the
         *   offset does not include the 4-byte function signature."
         *
         */
        Topology.TypeTree memory node = Topology.typeTree(condition);
        __block__(data, 4, node, node.children.length, false, result);
        result.location = 0;
        result.size = data.length;
    }

    /**
     * @dev Walks through a parameter encoding tree and maps their location and
     * size within calldata.
     * @param data The encoded transaction data.
     * @param location The current offset within the calldata buffer.
     * @param node The current node being traversed within the parameter tree.
     * @param result The location and size of the parameter within calldata.
     */
    function _walk(
        bytes calldata data,
        uint256 location,
        Topology.TypeTree memory node,
        ParameterPayload memory result
    ) private pure {
        ParameterType paramType = node.paramType;

        if (paramType == ParameterType.Static) {
            result.size = 32;
        } else if (paramType == ParameterType.Dynamic) {
            result.size = 32 + _ceil32(uint256(word(data, location)));
        } else if (paramType == ParameterType.Tuple) {
            __block__(
                data,
                location,
                node,
                node.children.length,
                false,
                result
            );
        } else if (paramType == ParameterType.Array) {
            __block__(
                data,
                location + 32,
                node,
                uint256(word(data, location)),
                true,
                result
            );
            result.size += 32;
        } else if (
            paramType == ParameterType.Calldata ||
            paramType == ParameterType.AbiEncoded
        ) {
            __block__(
                data,
                location + 32 + (paramType == ParameterType.Calldata ? 4 : 0),
                node,
                node.children.length,
                false,
                result
            );
            result.size = 32 + _ceil32(uint256(word(data, location)));
        }
        result.location = location;
    }

    /**
     * @dev Recursively walk through the TypeTree to decode a block of parameters.
     * @param data The encoded transaction data.
     * @param location The current location of the parameter block being processed.
     * @param node The current TypeTree node being processed.
     * @param length The number of parts in the block.
     * @param template whether first child is type descriptor for all parts.
     * @param result The decoded ParameterPayload.
     */
    function __block__(
        bytes calldata data,
        uint256 location,
        Topology.TypeTree memory node,
        uint256 length,
        bool template,
        ParameterPayload memory result
    ) private pure {
        result.children = new ParameterPayload[](length);
        bool isInline;
        if (template) isInline = Topology.isInline(node.children[0]);

        uint256 offset;
        for (uint256 i; i < length; ) {
            if (!template) isInline = Topology.isInline(node.children[i]);

            _walk(
                data,
                _locationInBlock(data, location, offset, isInline),
                node.children[template ? 0 : i],
                result.children[i]
            );

            uint256 childSize = result.children[i].size;
            result.size += isInline ? childSize : childSize + 32;
            offset += isInline ? childSize : 32;

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Returns the location of a block part, which may be located inline
     * within the block - at the HEAD - or at an offset relative to the start
     * of the block - at the TAIL.
     *
     * @param data The encoded transaction data.
     * @param location The location of the block within the calldata buffer.
     * @param offset The offset of the block part, relative to the start of the block.
     * @param isInline Whether the block part is located inline within the block.
     *
     * @return The location of the block part within the calldata buffer.
     */
    function _locationInBlock(
        bytes calldata data,
        uint256 location,
        uint256 offset,
        bool isInline
    ) private pure returns (uint256) {
        uint256 headLocation = location + offset;
        if (isInline) {
            return headLocation;
        } else {
            return location + uint256(word(data, headLocation));
        }
    }

    /**
     * @dev Plucks a slice of bytes from calldata.
     * @param data The calldata to pluck the slice from.
     * @param location The starting location of the slice.
     * @param size The size of the slice.
     * @return A slice of bytes from calldata.
     */
    function pluck(
        bytes calldata data,
        uint256 location,
        uint256 size
    ) internal pure returns (bytes calldata) {
        return data[location:location + size];
    }

    /**
     * @dev Loads a word from calldata.
     * @param data The calldata to load the word from.
     * @param location The starting location of the slice.
     * @return result 32 byte word from calldata.
     */
    function word(
        bytes calldata data,
        uint256 location
    ) internal pure returns (bytes32 result) {
        if (location + 32 > data.length) {
            revert CalldataOutOfBounds();
        }
        assembly {
            result := calldataload(add(data.offset, location))
        }
    }

    function _ceil32(uint256 size) private pure returns (uint256) {
        // pad size. Source: http://www.cs.nott.ac.uk/~psarb2/G51MPC/slides/NumberLogic.pdf
        return ((size + 32 - 1) / 32) * 32;
    }
}


// File: contracts/Integrity.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./Topology.sol";

/**
 * @title Integrity, A library that validates condition integrity, and
 * adherence to the expected input structure and rules.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
library Integrity {
    error UnsuitableRootNode();

    error NotBFS();

    error UnsuitableParameterType(uint256 index);

    error UnsuitableCompValue(uint256 index);

    error UnsupportedOperator(uint256 index);

    error UnsuitableParent(uint256 index);

    error UnsuitableChildCount(uint256 index);

    error UnsuitableChildTypeTree(uint256 index);

    function enforce(ConditionFlat[] memory conditions) external pure {
        _root(conditions);
        for (uint256 i = 0; i < conditions.length; ++i) {
            _node(conditions[i], i);
        }
        _tree(conditions);
    }

    function _root(ConditionFlat[] memory conditions) private pure {
        uint256 count;

        for (uint256 i; i < conditions.length; ++i) {
            if (conditions[i].parent == i) ++count;
        }
        if (count != 1 || conditions[0].parent != 0) {
            revert UnsuitableRootNode();
        }
    }

    function _node(ConditionFlat memory condition, uint256 index) private pure {
        Operator operator = condition.operator;
        ParameterType paramType = condition.paramType;
        bytes memory compValue = condition.compValue;
        if (operator == Operator.Pass) {
            if (condition.compValue.length != 0) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator >= Operator.And && operator <= Operator.Nor) {
            if (paramType != ParameterType.None) {
                revert UnsuitableParameterType(index);
            }
            if (condition.compValue.length != 0) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator == Operator.Matches) {
            if (
                paramType != ParameterType.Tuple &&
                paramType != ParameterType.Array &&
                paramType != ParameterType.Calldata &&
                paramType != ParameterType.AbiEncoded
            ) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 0) {
                revert UnsuitableCompValue(index);
            }
        } else if (
            operator == Operator.ArraySome ||
            operator == Operator.ArrayEvery ||
            operator == Operator.ArraySubset
        ) {
            if (paramType != ParameterType.Array) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 0) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator == Operator.EqualToAvatar) {
            if (paramType != ParameterType.Static) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 0) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator == Operator.EqualTo) {
            if (
                paramType != ParameterType.Static &&
                paramType != ParameterType.Dynamic &&
                paramType != ParameterType.Tuple &&
                paramType != ParameterType.Array
            ) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length == 0 || compValue.length % 32 != 0) {
                revert UnsuitableCompValue(index);
            }
        } else if (
            operator == Operator.GreaterThan ||
            operator == Operator.LessThan ||
            operator == Operator.SignedIntGreaterThan ||
            operator == Operator.SignedIntLessThan
        ) {
            if (paramType != ParameterType.Static) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 32) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator == Operator.Bitmask) {
            if (
                paramType != ParameterType.Static &&
                paramType != ParameterType.Dynamic
            ) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 32) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator == Operator.Custom) {
            if (compValue.length != 32) {
                revert UnsuitableCompValue(index);
            }
        } else if (operator == Operator.WithinAllowance) {
            if (paramType != ParameterType.Static) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 32) {
                revert UnsuitableCompValue(index);
            }
        } else if (
            operator == Operator.EtherWithinAllowance ||
            operator == Operator.CallWithinAllowance
        ) {
            if (paramType != ParameterType.None) {
                revert UnsuitableParameterType(index);
            }
            if (compValue.length != 32) {
                revert UnsuitableCompValue(index);
            }
        } else {
            revert UnsupportedOperator(index);
        }
    }

    function _tree(ConditionFlat[] memory conditions) private pure {
        uint256 length = conditions.length;
        // check BFS
        for (uint256 i = 1; i < length; ++i) {
            if (conditions[i - 1].parent > conditions[i].parent) {
                revert NotBFS();
            }
        }

        for (uint256 i = 0; i < length; ++i) {
            if (
                (conditions[i].operator == Operator.EtherWithinAllowance ||
                    conditions[i].operator == Operator.CallWithinAllowance) &&
                conditions[conditions[i].parent].paramType !=
                ParameterType.Calldata
            ) {
                revert UnsuitableParent(i);
            }
        }

        Topology.Bounds[] memory childrenBounds = Topology.childrenBounds(
            conditions
        );

        for (uint256 i = 0; i < conditions.length; i++) {
            ConditionFlat memory condition = conditions[i];
            Topology.Bounds memory childBounds = childrenBounds[i];

            if (condition.paramType == ParameterType.None) {
                if (
                    (condition.operator == Operator.EtherWithinAllowance ||
                        condition.operator == Operator.CallWithinAllowance) &&
                    childBounds.length != 0
                ) {
                    revert UnsuitableChildCount(i);
                }
                if (
                    (condition.operator >= Operator.And &&
                        condition.operator <= Operator.Nor)
                ) {
                    if (childBounds.length == 0) {
                        revert UnsuitableChildCount(i);
                    }
                }
            } else if (
                condition.paramType == ParameterType.Static ||
                condition.paramType == ParameterType.Dynamic
            ) {
                if (childBounds.length != 0) {
                    revert UnsuitableChildCount(i);
                }
            } else if (
                condition.paramType == ParameterType.Tuple ||
                condition.paramType == ParameterType.Calldata ||
                condition.paramType == ParameterType.AbiEncoded
            ) {
                if (childBounds.length == 0) {
                    revert UnsuitableChildCount(i);
                }
            } else {
                assert(condition.paramType == ParameterType.Array);

                if (childBounds.length == 0) {
                    revert UnsuitableChildCount(i);
                }

                if (
                    (condition.operator == Operator.ArraySome ||
                        condition.operator == Operator.ArrayEvery) &&
                    childBounds.length != 1
                ) {
                    revert UnsuitableChildCount(i);
                } else if (
                    condition.operator == Operator.ArraySubset &&
                    childBounds.length > 256
                ) {
                    revert UnsuitableChildCount(i);
                }
            }
        }

        for (uint256 i = 0; i < conditions.length; i++) {
            ConditionFlat memory condition = conditions[i];
            if (
                ((condition.operator >= Operator.And &&
                    condition.operator <= Operator.Nor) ||
                    condition.paramType == ParameterType.Array) &&
                childrenBounds[i].length > 1
            ) {
                _compatibleSiblingTypes(conditions, i, childrenBounds);
            }
        }

        Topology.TypeTree memory typeTree = Topology.typeTree(
            conditions,
            0,
            childrenBounds
        );

        if (typeTree.paramType != ParameterType.Calldata) {
            revert UnsuitableRootNode();
        }
    }

    function _compatibleSiblingTypes(
        ConditionFlat[] memory conditions,
        uint256 index,
        Topology.Bounds[] memory childrenBounds
    ) private pure {
        uint256 start = childrenBounds[index].start;
        uint256 end = childrenBounds[index].end;

        for (uint256 j = start + 1; j < end; ++j) {
            if (
                !_isTypeMatch(conditions, start, j, childrenBounds) &&
                !_isTypeEquivalent(conditions, start, j, childrenBounds)
            ) {
                revert UnsuitableChildTypeTree(index);
            }
        }
    }

    function _isTypeMatch(
        ConditionFlat[] memory conditions,
        uint256 i,
        uint256 j,
        Topology.Bounds[] memory childrenBounds
    ) private pure returns (bool) {
        return
            typeTreeId(Topology.typeTree(conditions, i, childrenBounds)) ==
            typeTreeId(Topology.typeTree(conditions, j, childrenBounds));
    }

    function _isTypeEquivalent(
        ConditionFlat[] memory conditions,
        uint256 i,
        uint256 j,
        Topology.Bounds[] memory childrenBounds
    ) private pure returns (bool) {
        ParameterType leftParamType = Topology
            .typeTree(conditions, i, childrenBounds)
            .paramType;
        return
            (leftParamType == ParameterType.Calldata ||
                leftParamType == ParameterType.AbiEncoded) &&
            Topology.typeTree(conditions, j, childrenBounds).paramType ==
            ParameterType.Dynamic;
    }

    function typeTreeId(
        Topology.TypeTree memory node
    ) private pure returns (bytes32) {
        uint256 childCount = node.children.length;
        if (childCount > 0) {
            bytes32[] memory ids = new bytes32[](node.children.length);
            for (uint256 i = 0; i < childCount; ++i) {
                ids[i] = typeTreeId(node.children[i]);
            }

            return keccak256(abi.encodePacked(node.paramType, "-", ids));
        } else {
            return bytes32(uint256(node.paramType));
        }
    }
}


// File: contracts/packers/BufferPacker.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "../Types.sol";

/**
 * @title BufferPacker a library that provides packing and unpacking functions
 * for conditions. It allows packing externally provided ConditionsFlat[] into
 * a storage-optimized buffer, and later unpack it into memory.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
library BufferPacker {
    // HEADER (stored as a single word in storage)
    // 2   bytes -> count (Condition count)
    // 1   bytes -> options (ExecutionOptions)
    // 1   bytes -> isWildcarded
    // 8   bytes -> unused
    // 20  bytes -> pointer (address containining packed conditions)
    uint256 private constant OFFSET_COUNT = 240;
    uint256 private constant OFFSET_OPTIONS = 224;
    uint256 private constant OFFSET_IS_WILDCARDED = 216;
    uint256 private constant MASK_COUNT = 0xffff << OFFSET_COUNT;
    uint256 private constant MASK_OPTIONS = 0xff << OFFSET_OPTIONS;
    uint256 private constant MASK_IS_WILDCARDED = 0x1 << OFFSET_IS_WILDCARDED;
    // CONDITION (stored as runtimeBytecode at pointer address kept in header)
    // 8    bits -> parent
    // 3    bits -> type
    // 5    bits -> operator
    uint256 private constant BYTES_PER_CONDITION = 2;
    uint16 private constant OFFSET_PARENT = 8;
    uint16 private constant OFFSET_PARAM_TYPE = 5;
    uint16 private constant OFFSET_OPERATOR = 0;
    uint16 private constant MASK_PARENT = uint16(0xff << OFFSET_PARENT);
    uint16 private constant MASK_PARAM_TYPE = uint16(0x07 << OFFSET_PARAM_TYPE);
    uint16 private constant MASK_OPERATOR = uint16(0x1f << OFFSET_OPERATOR);

    function packedSize(
        ConditionFlat[] memory conditions
    ) internal pure returns (uint256 result) {
        uint256 count = conditions.length;

        result = count * BYTES_PER_CONDITION;
        for (uint256 i; i < count; ++i) {
            if (conditions[i].operator >= Operator.EqualTo) {
                result += 32;
            }
        }
    }

    function packHeader(
        uint256 count,
        ExecutionOptions options,
        address pointer
    ) internal pure returns (bytes32) {
        return
            bytes32(count << OFFSET_COUNT) |
            (bytes32(uint256(options)) << OFFSET_OPTIONS) |
            bytes32(uint256(uint160(pointer)));
    }

    function packHeaderAsWildcarded(
        ExecutionOptions options
    ) internal pure returns (bytes32) {
        return
            bytes32(uint256(options) << OFFSET_OPTIONS) |
            bytes32(MASK_IS_WILDCARDED);
    }

    function unpackHeader(
        bytes32 header
    ) internal pure returns (uint256 count, address pointer) {
        count = (uint256(header) & MASK_COUNT) >> OFFSET_COUNT;
        pointer = address(bytes20(uint160(uint256(header))));
    }

    function unpackOptions(
        bytes32 header
    ) internal pure returns (bool isWildcarded, ExecutionOptions options) {
        isWildcarded = uint256(header) & MASK_IS_WILDCARDED != 0;
        options = ExecutionOptions(
            (uint256(header) & MASK_OPTIONS) >> OFFSET_OPTIONS
        );
    }

    function packCondition(
        bytes memory buffer,
        uint256 index,
        ConditionFlat memory condition
    ) internal pure {
        uint256 offset = index * BYTES_PER_CONDITION;
        buffer[offset] = bytes1(condition.parent);
        buffer[offset + 1] = bytes1(
            (uint8(condition.paramType) << uint8(OFFSET_PARAM_TYPE)) |
                uint8(condition.operator)
        );
    }

    function packCompValue(
        bytes memory buffer,
        uint256 offset,
        ConditionFlat memory condition
    ) internal pure {
        bytes32 word = condition.operator == Operator.EqualTo
            ? keccak256(condition.compValue)
            : bytes32(condition.compValue);

        assembly {
            mstore(add(buffer, offset), word)
        }
    }

    function unpackBody(
        bytes memory buffer,
        uint256 count
    )
        internal
        pure
        returns (ConditionFlat[] memory result, bytes32[] memory compValues)
    {
        result = new ConditionFlat[](count);
        compValues = new bytes32[](count);

        bytes32 word;
        uint256 offset = 32;
        uint256 compValueOffset = 32 + count * BYTES_PER_CONDITION;

        for (uint256 i; i < count; ) {
            assembly {
                word := mload(add(buffer, offset))
            }
            offset += BYTES_PER_CONDITION;

            uint16 bits = uint16(bytes2(word));
            ConditionFlat memory condition = result[i];
            condition.parent = uint8((bits & MASK_PARENT) >> OFFSET_PARENT);
            condition.paramType = ParameterType(
                (bits & MASK_PARAM_TYPE) >> OFFSET_PARAM_TYPE
            );
            condition.operator = Operator(bits & MASK_OPERATOR);

            if (condition.operator >= Operator.EqualTo) {
                assembly {
                    word := mload(add(buffer, compValueOffset))
                }
                compValueOffset += 32;
                compValues[i] = word;
            }
            unchecked {
                ++i;
            }
        }
    }
}


// File: contracts/packers/Packer.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "@gnosis.pm/zodiac/contracts/core/Modifier.sol";

import "./BufferPacker.sol";

/**
 * @title Packer - a library that coordinates the process of packing
 * conditionsFlat into a storage optimized buffer.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
library Packer {
    function pack(
        ConditionFlat[] memory conditionsFlat
    ) external pure returns (bytes memory buffer) {
        _removeExtraneousOffsets(conditionsFlat);

        buffer = new bytes(BufferPacker.packedSize(conditionsFlat));

        uint256 count = conditionsFlat.length;
        uint256 offset = 32 + count * 2;
        for (uint256 i; i < count; ++i) {
            BufferPacker.packCondition(buffer, i, conditionsFlat[i]);
            if (conditionsFlat[i].operator >= Operator.EqualTo) {
                BufferPacker.packCompValue(buffer, offset, conditionsFlat[i]);
                offset += 32;
            }
        }
    }

    /**
     * @dev This function removes unnecessary offsets from compValue fields of
     * the `conditions` array. Its purpose is to ensure a consistent API where
     * every `compValue` provided for use in `Operations.EqualsTo` is obtained
     * by calling `abi.encode` directly.
     *
     * By removing the leading extraneous offsets this function makes
     * abi.encode(...) match the output produced by Decoder inspection.
     * Without it, the encoded fields would need to be patched externally
     * depending on whether the payload is fully encoded inline or not.
     *
     * @param conditionsFlat Array of ConditionFlat structs to remove extraneous
     * offsets from
     */
    function _removeExtraneousOffsets(
        ConditionFlat[] memory conditionsFlat
    ) private pure {
        uint256 count = conditionsFlat.length;
        for (uint256 i; i < count; ++i) {
            if (
                conditionsFlat[i].operator == Operator.EqualTo &&
                !_isInline(conditionsFlat, i)
            ) {
                bytes memory compValue = conditionsFlat[i].compValue;
                uint256 length = compValue.length;
                assembly {
                    compValue := add(compValue, 32)
                    mstore(compValue, sub(length, 32))
                }
                conditionsFlat[i].compValue = compValue;
            }
        }
    }

    function _isInline(
        ConditionFlat[] memory conditions,
        uint256 index
    ) private pure returns (bool) {
        ParameterType paramType = conditions[index].paramType;
        if (paramType == ParameterType.Static) {
            return true;
        } else if (
            paramType == ParameterType.Dynamic ||
            paramType == ParameterType.Array ||
            paramType == ParameterType.Calldata ||
            paramType == ParameterType.AbiEncoded
        ) {
            return false;
        } else {
            uint256 length = conditions.length;

            for (uint256 j = index + 1; j < length; ++j) {
                uint8 parent = conditions[j].parent;
                if (parent < index) {
                    continue;
                }

                if (parent > index) {
                    break;
                }

                if (!_isInline(conditions, j)) {
                    return false;
                }
            }
            return true;
        }
    }
}


// File: contracts/Periphery.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./adapters/Types.sol";

/**
 * @title Periphery - a coordinating component that facilitates plug-and-play
 * functionality for the Zodiac Roles Mod through the use of adapters.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
abstract contract Periphery is OwnableUpgradeable {
    event SetUnwrapAdapter(
        address to,
        bytes4 selector,
        ITransactionUnwrapper adapter
    );

    mapping(bytes32 => ITransactionUnwrapper) public unwrappers;

    function setTransactionUnwrapper(
        address to,
        bytes4 selector,
        ITransactionUnwrapper adapter
    ) external onlyOwner {
        unwrappers[bytes32(bytes20(to)) | (bytes32(selector) >> 160)] = adapter;
        emit SetUnwrapAdapter(to, selector, adapter);
    }

    function getTransactionUnwrapper(
        address to,
        bytes4 selector
    ) internal view returns (ITransactionUnwrapper) {
        return unwrappers[bytes32(bytes20(to)) | (bytes32(selector) >> 160)];
    }
}


// File: contracts/PermissionBuilder.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./Core.sol";
import "./Integrity.sol";

import "./packers/BufferPacker.sol";

/**
 * @title PermissionBuilder - a component of the Zodiac Roles Mod that is
 * responsible for constructing, managing, granting, and revoking all types
 * of permission data.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 * @author Jan-Felix Schwarz  - <jan-felix.schwarz@gnosis.io>
 */
abstract contract PermissionBuilder is Core {
    event AllowTarget(
        bytes32 roleKey,
        address targetAddress,
        ExecutionOptions options
    );
    event RevokeTarget(bytes32 roleKey, address targetAddress);
    event ScopeTarget(bytes32 roleKey, address targetAddress);

    event AllowFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ExecutionOptions options
    );
    event RevokeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector
    );
    event ScopeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ConditionFlat[] conditions,
        ExecutionOptions options
    );

    event SetAllowance(
        bytes32 allowanceKey,
        uint128 balance,
        uint128 maxRefill,
        uint128 refill,
        uint64 period,
        uint64 timestamp
    );

    /// @dev Allows transactions to a target address.
    /// @param roleKey identifier of the role to be modified.
    /// @param targetAddress Destination address of transaction.
    /// @param options designates if a transaction can send ether and/or delegatecall to target.
    function allowTarget(
        bytes32 roleKey,
        address targetAddress,
        ExecutionOptions options
    ) external onlyOwner {
        roles[roleKey].targets[targetAddress] = TargetAddress({
            clearance: Clearance.Target,
            options: options
        });
        emit AllowTarget(roleKey, targetAddress, options);
    }

    /// @dev Removes transactions to a target address.
    /// @param roleKey identifier of the role to be modified.
    /// @param targetAddress Destination address of transaction.
    function revokeTarget(
        bytes32 roleKey,
        address targetAddress
    ) external onlyOwner {
        roles[roleKey].targets[targetAddress] = TargetAddress({
            clearance: Clearance.None,
            options: ExecutionOptions.None
        });
        emit RevokeTarget(roleKey, targetAddress);
    }

    /// @dev Designates only specific functions can be called.
    /// @param roleKey identifier of the role to be modified.
    /// @param targetAddress Destination address of transaction.
    function scopeTarget(
        bytes32 roleKey,
        address targetAddress
    ) external onlyOwner {
        roles[roleKey].targets[targetAddress] = TargetAddress({
            clearance: Clearance.Function,
            options: ExecutionOptions.None
        });
        emit ScopeTarget(roleKey, targetAddress);
    }

    /// @dev Specifies the functions that can be called.
    /// @param roleKey identifier of the role to be modified.
    /// @param targetAddress Destination address of transaction.
    /// @param selector 4 byte function selector.
    /// @param options designates if a transaction can send ether and/or delegatecall to target.
    function allowFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ExecutionOptions options
    ) external onlyOwner {
        roles[roleKey].scopeConfig[_key(targetAddress, selector)] = BufferPacker
            .packHeaderAsWildcarded(options);

        emit AllowFunction(roleKey, targetAddress, selector, options);
    }

    /// @dev Removes the functions that can be called.
    /// @param roleKey identifier of the role to be modified.
    /// @param targetAddress Destination address of transaction.
    /// @param selector 4 byte function selector.
    function revokeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector
    ) external onlyOwner {
        delete roles[roleKey].scopeConfig[_key(targetAddress, selector)];
        emit RevokeFunction(roleKey, targetAddress, selector);
    }

    /// @dev Sets conditions to enforce on calls to the specified target.
    /// @param roleKey identifier of the role to be modified.
    /// @param targetAddress Destination address of transaction.
    /// @param selector 4 byte function selector.
    /// @param conditions The conditions to enforce.
    /// @param options designates if a transaction can send ether and/or delegatecall to target.
    function scopeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ConditionFlat[] memory conditions,
        ExecutionOptions options
    ) external onlyOwner {
        Integrity.enforce(conditions);

        _store(
            roles[roleKey],
            _key(targetAddress, selector),
            conditions,
            options
        );

        emit ScopeFunction(
            roleKey,
            targetAddress,
            selector,
            conditions,
            options
        );
    }

    function setAllowance(
        bytes32 key,
        uint128 balance,
        uint128 maxRefill,
        uint128 refill,
        uint64 period,
        uint64 timestamp
    ) external onlyOwner {
        maxRefill = maxRefill != 0 ? maxRefill : type(uint128).max;
        timestamp = timestamp != 0 ? timestamp : uint64(block.timestamp);

        allowances[key] = Allowance({
            refill: refill,
            maxRefill: maxRefill,
            period: period,
            timestamp: timestamp,
            balance: balance
        });
        emit SetAllowance(key, balance, maxRefill, refill, period, timestamp);
    }
}


// File: contracts/PermissionChecker.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import "./Consumptions.sol";
import "./Core.sol";
import "./Decoder.sol";
import "./Periphery.sol";

import "./packers/BufferPacker.sol";

/**
 * @title PermissionChecker - a component of Zodiac Roles Mod responsible
 * for enforcing and authorizing actions performed on behalf of a role.
 *
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 * @author Jan-Felix Schwarz  - <jan-felix.schwarz@gnosis.io>
 */
abstract contract PermissionChecker is Core, Periphery {
    function _authorize(
        bytes32 roleKey,
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) internal moduleOnly returns (Consumption[] memory) {
        // We never authorize the zero role, as it could clash with the
        // unassigned default role
        if (roleKey == 0) {
            revert NoMembership();
        }

        Role storage role = roles[roleKey];
        if (!role.members[sentOrSignedByModule()]) {
            revert NoMembership();
        }

        ITransactionUnwrapper adapter = getTransactionUnwrapper(
            to,
            bytes4(data)
        );

        Status status;
        Result memory result;
        if (address(adapter) == address(0)) {
            (status, result) = _transaction(
                role,
                to,
                value,
                data,
                operation,
                result.consumptions
            );
        } else {
            (status, result) = _multiEntrypoint(
                ITransactionUnwrapper(adapter),
                role,
                to,
                value,
                data,
                operation
            );
        }
        if (status != Status.Ok) {
            revert ConditionViolation(status, result.info);
        }

        return result.consumptions;
    }

    function _multiEntrypoint(
        ITransactionUnwrapper adapter,
        Role storage role,
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) private view returns (Status status, Result memory result) {
        try adapter.unwrap(to, value, data, operation) returns (
            UnwrappedTransaction[] memory transactions
        ) {
            for (uint256 i; i < transactions.length; ) {
                UnwrappedTransaction memory transaction = transactions[i];
                uint256 left = transaction.dataLocation;
                uint256 right = left + transaction.dataSize;
                (status, result) = _transaction(
                    role,
                    transaction.to,
                    transaction.value,
                    data[left:right],
                    transaction.operation,
                    result.consumptions
                );
                if (status != Status.Ok) {
                    return (status, result);
                }
                unchecked {
                    ++i;
                }
            }
        } catch {
            revert MalformedMultiEntrypoint();
        }
    }

    /// @dev Inspects an individual transaction and performs checks based on permission scoping.
    /// Wildcarded indicates whether params need to be inspected or not. When true, only ExecutionOptions are checked.
    /// @param role Role to check for.
    /// @param to Destination address of transaction.
    /// @param value Ether value of module transaction.
    /// @param data Data payload of module transaction.
    /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
    function _transaction(
        Role storage role,
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        Consumption[] memory consumptions
    ) private view returns (Status, Result memory) {
        if (data.length != 0 && data.length < 4) {
            revert FunctionSignatureTooShort();
        }

        if (role.targets[to].clearance == Clearance.Function) {
            bytes32 key = _key(to, bytes4(data));
            {
                bytes32 header = role.scopeConfig[key];
                if (header == 0) {
                    return (
                        Status.FunctionNotAllowed,
                        Result({
                            consumptions: consumptions,
                            info: bytes32(bytes4(data))
                        })
                    );
                }

                (bool isWildcarded, ExecutionOptions options) = BufferPacker
                    .unpackOptions(header);

                Status status = _executionOptions(value, operation, options);
                if (status != Status.Ok) {
                    return (
                        status,
                        Result({consumptions: consumptions, info: 0})
                    );
                }

                if (isWildcarded) {
                    return (
                        Status.Ok,
                        Result({consumptions: consumptions, info: 0})
                    );
                }
            }

            return
                _scopedFunction(
                    role,
                    key,
                    data,
                    Context({
                        to: to,
                        value: value,
                        operation: operation,
                        consumptions: consumptions
                    })
                );
        } else if (role.targets[to].clearance == Clearance.Target) {
            return (
                _executionOptions(value, operation, role.targets[to].options),
                Result({consumptions: consumptions, info: 0})
            );
        } else {
            return (
                Status.TargetAddressNotAllowed,
                Result({consumptions: consumptions, info: 0})
            );
        }
    }

    /// @dev Examines the ether value and operation for a given role target.
    /// @param value Ether value of module transaction.
    /// @param operation Operation type of module transaction: 0 == call, 1 == delegate call.
    /// @param options Determines if a transaction can send ether and/or delegatecall to target.
    function _executionOptions(
        uint256 value,
        Enum.Operation operation,
        ExecutionOptions options
    ) private pure returns (Status) {
        // isSend && !canSend
        if (
            value > 0 &&
            options != ExecutionOptions.Send &&
            options != ExecutionOptions.Both
        ) {
            return Status.SendNotAllowed;
        }

        // isDelegateCall && !canDelegateCall
        if (
            operation == Enum.Operation.DelegateCall &&
            options != ExecutionOptions.DelegateCall &&
            options != ExecutionOptions.Both
        ) {
            return Status.DelegateCallNotAllowed;
        }

        return Status.Ok;
    }

    function _scopedFunction(
        Role storage role,
        bytes32 key,
        bytes calldata data,
        Context memory context
    ) private view returns (Status, Result memory) {
        (Condition memory condition, Consumption[] memory consumptions) = _load(
            role,
            key
        );
        ParameterPayload memory payload = Decoder.inspect(data, condition);

        context.consumptions = context.consumptions.length > 0
            ? Consumptions.merge(context.consumptions, consumptions)
            : consumptions;

        return _walk(data, condition, payload, context);
    }

    function _walk(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status, Result memory) {
        Operator operator = condition.operator;

        if (operator < Operator.EqualTo) {
            if (operator == Operator.Pass) {
                return (
                    Status.Ok,
                    Result({consumptions: context.consumptions, info: 0})
                );
            } else if (operator == Operator.Matches) {
                return _matches(data, condition, payload, context);
            } else if (operator == Operator.And) {
                return _and(data, condition, payload, context);
            } else if (operator == Operator.Or) {
                return _or(data, condition, payload, context);
            } else if (operator == Operator.Nor) {
                return _nor(data, condition, payload, context);
            } else if (operator == Operator.ArraySome) {
                return _arraySome(data, condition, payload, context);
            } else if (operator == Operator.ArrayEvery) {
                return _arrayEvery(data, condition, payload, context);
            } else {
                assert(operator == Operator.ArraySubset);
                return _arraySubset(data, condition, payload, context);
            }
        } else {
            if (operator <= Operator.LessThan) {
                return (
                    _compare(data, condition, payload),
                    Result({consumptions: context.consumptions, info: 0})
                );
            } else if (operator <= Operator.SignedIntLessThan) {
                return (
                    _compareSignedInt(data, condition, payload),
                    Result({consumptions: context.consumptions, info: 0})
                );
            } else if (operator == Operator.Bitmask) {
                return (
                    _bitmask(data, condition, payload),
                    Result({consumptions: context.consumptions, info: 0})
                );
            } else if (operator == Operator.Custom) {
                return _custom(data, condition, payload, context);
            } else if (operator == Operator.WithinAllowance) {
                return _withinAllowance(data, condition, payload, context);
            } else if (operator == Operator.EtherWithinAllowance) {
                return _etherWithinAllowance(condition, context);
            } else {
                assert(operator == Operator.CallWithinAllowance);
                return _callWithinAllowance(condition, context);
            }
        }
    }

    function _matches(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status status, Result memory result) {
        result.consumptions = context.consumptions;

        if (condition.children.length != payload.children.length) {
            return (Status.ParameterNotAMatch, result);
        }

        for (uint256 i; i < condition.children.length; ) {
            (status, result) = _walk(
                data,
                condition.children[i],
                payload.children[i],
                Context({
                    to: context.to,
                    value: context.value,
                    operation: context.operation,
                    consumptions: result.consumptions
                })
            );
            if (status != Status.Ok) {
                return (
                    status,
                    Result({
                        consumptions: context.consumptions,
                        info: result.info
                    })
                );
            }
            unchecked {
                ++i;
            }
        }

        return (Status.Ok, result);
    }

    function _and(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status status, Result memory result) {
        result.consumptions = context.consumptions;

        for (uint256 i; i < condition.children.length; ) {
            (status, result) = _walk(
                data,
                condition.children[i],
                payload,
                Context({
                    to: context.to,
                    value: context.value,
                    operation: context.operation,
                    consumptions: result.consumptions
                })
            );
            if (status != Status.Ok) {
                return (
                    status,
                    Result({
                        consumptions: context.consumptions,
                        info: result.info
                    })
                );
            }
            unchecked {
                ++i;
            }
        }
        return (Status.Ok, result);
    }

    function _or(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status status, Result memory result) {
        result.consumptions = context.consumptions;

        for (uint256 i; i < condition.children.length; ) {
            (status, result) = _walk(
                data,
                condition.children[i],
                payload,
                Context({
                    to: context.to,
                    value: context.value,
                    operation: context.operation,
                    consumptions: result.consumptions
                })
            );
            if (status == Status.Ok) {
                return (status, result);
            }
            unchecked {
                ++i;
            }
        }

        return (
            Status.OrViolation,
            Result({consumptions: context.consumptions, info: 0})
        );
    }

    function _nor(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status status, Result memory) {
        for (uint256 i; i < condition.children.length; ) {
            (status, ) = _walk(data, condition.children[i], payload, context);
            if (status == Status.Ok) {
                return (
                    Status.NorViolation,
                    Result({consumptions: context.consumptions, info: 0})
                );
            }
            unchecked {
                ++i;
            }
        }
        return (
            Status.Ok,
            Result({consumptions: context.consumptions, info: 0})
        );
    }

    function _arraySome(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status status, Result memory result) {
        result.consumptions = context.consumptions;

        uint256 length = condition.children.length;
        for (uint256 i; i < length; ) {
            (status, result) = _walk(
                data,
                condition.children[0],
                payload.children[i],
                Context({
                    to: context.to,
                    value: context.value,
                    operation: context.operation,
                    consumptions: result.consumptions
                })
            );
            if (status == Status.Ok) {
                return (status, result);
            }
            unchecked {
                ++i;
            }
        }
        return (
            Status.NoArrayElementPasses,
            Result({consumptions: context.consumptions, info: 0})
        );
    }

    function _arrayEvery(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status status, Result memory result) {
        result.consumptions = context.consumptions;

        for (uint256 i; i < payload.children.length; ) {
            (status, result) = _walk(
                data,
                condition.children[0],
                payload.children[i],
                Context({
                    to: context.to,
                    value: context.value,
                    operation: context.operation,
                    consumptions: result.consumptions
                })
            );
            if (status != Status.Ok) {
                return (
                    Status.NotEveryArrayElementPasses,
                    Result({consumptions: context.consumptions, info: 0})
                );
            }
            unchecked {
                ++i;
            }
        }
        return (Status.Ok, result);
    }

    function _arraySubset(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status, Result memory result) {
        result.consumptions = context.consumptions;

        if (
            payload.children.length == 0 ||
            payload.children.length > condition.children.length
        ) {
            return (Status.ParameterNotSubsetOfAllowed, result);
        }

        uint256 taken;
        for (uint256 i; i < payload.children.length; ++i) {
            bool found = false;
            for (uint256 j; j < condition.children.length; ++j) {
                if (taken & (1 << j) != 0) continue;

                (Status status, Result memory _result) = _walk(
                    data,
                    condition.children[j],
                    payload.children[i],
                    Context({
                        to: context.to,
                        value: context.value,
                        operation: context.operation,
                        consumptions: result.consumptions
                    })
                );
                if (status == Status.Ok) {
                    found = true;
                    taken |= 1 << j;
                    result = _result;
                    break;
                }
            }
            if (!found) {
                return (
                    Status.ParameterNotSubsetOfAllowed,
                    Result({consumptions: context.consumptions, info: 0})
                );
            }
        }

        return (Status.Ok, result);
    }

    function _compare(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload
    ) private pure returns (Status) {
        Operator operator = condition.operator;
        bytes32 compValue = condition.compValue;
        bytes32 value = operator == Operator.EqualTo
            ? keccak256(Decoder.pluck(data, payload.location, payload.size))
            : Decoder.word(data, payload.location);

        if (operator == Operator.EqualTo && value != compValue) {
            return Status.ParameterNotAllowed;
        } else if (operator == Operator.GreaterThan && value <= compValue) {
            return Status.ParameterLessThanAllowed;
        } else if (operator == Operator.LessThan && value >= compValue) {
            return Status.ParameterGreaterThanAllowed;
        } else {
            return Status.Ok;
        }
    }

    function _compareSignedInt(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload
    ) private pure returns (Status) {
        Operator operator = condition.operator;
        int256 compValue = int256(uint256(condition.compValue));
        int256 value = int256(uint256(Decoder.word(data, payload.location)));

        if (operator == Operator.SignedIntGreaterThan && value <= compValue) {
            return Status.ParameterLessThanAllowed;
        } else if (
            operator == Operator.SignedIntLessThan && value >= compValue
        ) {
            return Status.ParameterGreaterThanAllowed;
        } else {
            return Status.Ok;
        }
    }

    /**
     * Applies a shift and bitmask on the payload bytes and compares the
     * result to the expected value. The shift offset, bitmask, and expected
     * value are specified in the compValue parameter, which is tightly
     * packed as follows:
     * <2 bytes shift offset><15 bytes bitmask><15 bytes expected value>
     */
    function _bitmask(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload
    ) private pure returns (Status) {
        bytes32 compValue = condition.compValue;
        bool isInline = condition.paramType == ParameterType.Static;
        bytes calldata value = Decoder.pluck(
            data,
            payload.location + (isInline ? 0 : 32),
            payload.size - (isInline ? 0 : 32)
        );

        uint256 shift = uint16(bytes2(compValue));
        if (shift >= value.length) {
            return Status.BitmaskOverflow;
        }

        bytes32 rinse = bytes15(0xffffffffffffffffffffffffffffff);
        bytes32 mask = (compValue << 16) & rinse;
        // while its necessary to apply the rinse to the mask its not strictly
        // necessary to do so for the expected value, since we get remaining
        // 15 bytes anyway (shifting the word by 17 bytes)
        bytes32 expected = (compValue << (16 + 15 * 8)) & rinse;
        bytes32 slice = bytes32(value[shift:]);

        return
            (slice & mask) == expected ? Status.Ok : Status.BitmaskNotAllowed;
    }

    function _custom(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private view returns (Status, Result memory) {
        // 20 bytes on the left
        ICustomCondition adapter = ICustomCondition(
            address(bytes20(condition.compValue))
        );
        // 12 bytes on the right
        bytes12 extra = bytes12(uint96(uint256(condition.compValue)));

        (bool success, bytes32 info) = adapter.check(
            context.to,
            context.value,
            data,
            context.operation,
            payload.location,
            payload.size,
            extra
        );
        return (
            success ? Status.Ok : Status.CustomConditionViolation,
            Result({consumptions: context.consumptions, info: info})
        );
    }

    function _withinAllowance(
        bytes calldata data,
        Condition memory condition,
        ParameterPayload memory payload,
        Context memory context
    ) private pure returns (Status, Result memory) {
        uint256 value = uint256(Decoder.word(data, payload.location));
        return __consume(value, condition, context.consumptions);
    }

    function _etherWithinAllowance(
        Condition memory condition,
        Context memory context
    ) private pure returns (Status status, Result memory result) {
        (status, result) = __consume(
            context.value,
            condition,
            context.consumptions
        );
        return (
            status == Status.Ok ? Status.Ok : Status.EtherAllowanceExceeded,
            result
        );
    }

    function _callWithinAllowance(
        Condition memory condition,
        Context memory context
    ) private pure returns (Status status, Result memory result) {
        (status, result) = __consume(1, condition, context.consumptions);
        return (
            status == Status.Ok ? Status.Ok : Status.CallAllowanceExceeded,
            result
        );
    }

    function __consume(
        uint256 value,
        Condition memory condition,
        Consumption[] memory consumptions
    ) private pure returns (Status, Result memory) {
        (uint256 index, bool found) = Consumptions.find(
            consumptions,
            condition.compValue
        );
        assert(found);

        if (
            value + consumptions[index].consumed > consumptions[index].balance
        ) {
            return (
                Status.AllowanceExceeded,
                Result({
                    consumptions: consumptions,
                    info: consumptions[index].allowanceKey
                })
            );
        } else {
            consumptions = Consumptions.clone(consumptions);
            consumptions[index].consumed += uint128(value);
            return (Status.Ok, Result({consumptions: consumptions, info: 0}));
        }
    }

    struct Context {
        address to;
        uint256 value;
        Consumption[] consumptions;
        Enum.Operation operation;
    }

    struct Result {
        Consumption[] consumptions;
        bytes32 info;
    }

    enum Status {
        Ok,
        /// Role not allowed to delegate call to target address
        DelegateCallNotAllowed,
        /// Role not allowed to call target address
        TargetAddressNotAllowed,
        /// Role not allowed to call this function on target address
        FunctionNotAllowed,
        /// Role not allowed to send to target address
        SendNotAllowed,
        /// Or conition not met
        OrViolation,
        /// Nor conition not met
        NorViolation,
        /// Parameter value is not equal to allowed
        ParameterNotAllowed,
        /// Parameter value less than allowed
        ParameterLessThanAllowed,
        /// Parameter value greater than maximum allowed by role
        ParameterGreaterThanAllowed,
        /// Parameter value does not match
        ParameterNotAMatch,
        /// Array elements do not meet allowed criteria for every element
        NotEveryArrayElementPasses,
        /// Array elements do not meet allowed criteria for at least one element
        NoArrayElementPasses,
        /// Parameter value not a subset of allowed
        ParameterNotSubsetOfAllowed,
        /// Bitmask exceeded value length
        BitmaskOverflow,
        /// Bitmask not an allowed value
        BitmaskNotAllowed,
        CustomConditionViolation,
        AllowanceExceeded,
        CallAllowanceExceeded,
        EtherAllowanceExceeded
    }

    /// Sender is not a member of the role
    error NoMembership();

    /// Function signature too short
    error FunctionSignatureTooShort();

    /// Calldata unwrapping failed
    error MalformedMultiEntrypoint();

    error ConditionViolation(Status status, bytes32 info);
}


// File: contracts/PermissionLoader.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "@gnosis.pm/zodiac/contracts/core/Modifier.sol";
import "./Consumptions.sol";
import "./Core.sol";
import "./Topology.sol";
import "./WriteOnce.sol";

import "./packers/Packer.sol";

/**
 * @title PermissionLoader - a component of the Zodiac Roles Mod that handles
 * the writing and reading of permission data to and from storage.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 * @author Jan-Felix Schwarz  - <jan-felix.schwarz@gnosis.io>
 */
abstract contract PermissionLoader is Core {
    function _store(
        Role storage role,
        bytes32 key,
        ConditionFlat[] memory conditions,
        ExecutionOptions options
    ) internal override {
        bytes memory buffer = Packer.pack(conditions);
        address pointer = WriteOnce.store(buffer);

        role.scopeConfig[key] = BufferPacker.packHeader(
            conditions.length,
            options,
            pointer
        );
    }

    function _load(
        Role storage role,
        bytes32 key
    )
        internal
        view
        override
        returns (Condition memory condition, Consumption[] memory consumptions)
    {
        (uint256 count, address pointer) = BufferPacker.unpackHeader(
            role.scopeConfig[key]
        );
        bytes memory buffer = WriteOnce.load(pointer);
        (
            ConditionFlat[] memory conditionsFlat,
            bytes32[] memory compValues
        ) = BufferPacker.unpackBody(buffer, count);

        uint256 allowanceCount;

        for (uint256 i; i < conditionsFlat.length; ) {
            Operator operator = conditionsFlat[i].operator;
            if (operator >= Operator.WithinAllowance) {
                ++allowanceCount;
            } else if (operator == Operator.EqualToAvatar) {
                // patch Operator.EqualToAvatar which in reality works as
                // a placeholder
                conditionsFlat[i].operator = Operator.EqualTo;
                compValues[i] = keccak256(abi.encode(avatar));
            }
            unchecked {
                ++i;
            }
        }

        _conditionTree(
            conditionsFlat,
            compValues,
            Topology.childrenBounds(conditionsFlat),
            0,
            condition
        );

        return (
            condition,
            allowanceCount > 0
                ? _consumptions(conditionsFlat, compValues, allowanceCount)
                : consumptions
        );
    }

    function _conditionTree(
        ConditionFlat[] memory conditionsFlat,
        bytes32[] memory compValues,
        Topology.Bounds[] memory childrenBounds,
        uint256 index,
        Condition memory treeNode
    ) private pure {
        // This function populates a buffer received as an argument instead of
        // instantiating a result object. This is an important gas optimization

        ConditionFlat memory conditionFlat = conditionsFlat[index];
        treeNode.paramType = conditionFlat.paramType;
        treeNode.operator = conditionFlat.operator;
        treeNode.compValue = compValues[index];

        if (childrenBounds[index].length == 0) {
            return;
        }

        uint256 start = childrenBounds[index].start;
        uint256 length = childrenBounds[index].length;

        treeNode.children = new Condition[](length);
        for (uint j; j < length; ) {
            _conditionTree(
                conditionsFlat,
                compValues,
                childrenBounds,
                start + j,
                treeNode.children[j]
            );
            unchecked {
                ++j;
            }
        }
    }

    function _consumptions(
        ConditionFlat[] memory conditions,
        bytes32[] memory compValues,
        uint256 maxAllowanceCount
    ) private view returns (Consumption[] memory result) {
        uint256 count = conditions.length;
        result = new Consumption[](maxAllowanceCount);

        uint256 insert;

        for (uint256 i; i < count; ++i) {
            if (conditions[i].operator < Operator.WithinAllowance) {
                continue;
            }

            bytes32 key = compValues[i];
            (, bool contains) = Consumptions.find(result, key);
            if (contains) {
                continue;
            }

            result[insert].allowanceKey = key;
            (result[insert].balance, ) = _accruedAllowance(
                allowances[key],
                uint64(block.timestamp)
            );
            insert++;
        }

        if (insert < maxAllowanceCount) {
            assembly {
                mstore(result, insert)
            }
        }
    }
}


// File: contracts/Roles.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./AllowanceTracker.sol";
import "./PermissionBuilder.sol";
import "./PermissionChecker.sol";
import "./PermissionLoader.sol";

/**
 * @title Zodiac Roles Mod - granular, role-based, access control for your
 * on-chain avatar accounts (like Safe).
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 * @author Jan-Felix Schwarz  - <jan-felix.schwarz@gnosis.io>
 * @author Auryn Macmillan    - <auryn.macmillan@gnosis.io>
 * @author Nathan Ginnever    - <nathan.ginnever@gnosis.io>
 */
contract Roles is
    Modifier,
    AllowanceTracker,
    PermissionBuilder,
    PermissionChecker,
    PermissionLoader
{
    mapping(address => bytes32) public defaultRoles;

    event AssignRoles(address module, bytes32[] roleKeys, bool[] memberOf);
    event RolesModSetup(
        address indexed initiator,
        address indexed owner,
        address indexed avatar,
        address target
    );
    event SetDefaultRole(address module, bytes32 defaultRoleKey);

    error ArraysDifferentLength();

    /// Sender is allowed to make this call, but the internal transaction failed
    error ModuleTransactionFailed();

    /// @param _owner Address of the owner
    /// @param _avatar Address of the avatar (e.g. a Gnosis Safe)
    /// @param _target Address of the contract that will call exec function
    constructor(address _owner, address _avatar, address _target) {
        bytes memory initParams = abi.encode(_owner, _avatar, _target);
        setUp(initParams);
    }

    /// @dev There is no zero address check as solidty will check for
    /// missing arguments and the space of invalid addresses is too large
    /// to check. Invalid avatar or target address can be reset by owner.
    function setUp(bytes memory initParams) public override initializer {
        (address _owner, address _avatar, address _target) = abi.decode(
            initParams,
            (address, address, address)
        );
        _transferOwnership(_owner);
        avatar = _avatar;
        target = _target;

        setupModules();

        emit RolesModSetup(msg.sender, _owner, _avatar, _target);
    }

    /// @dev Assigns and revokes roles to a given module.
    /// @param module Module on which to assign/revoke roles.
    /// @param roleKeys Roles to assign/revoke.
    /// @param memberOf Assign (true) or revoke (false) corresponding roleKeys.
    function assignRoles(
        address module,
        bytes32[] calldata roleKeys,
        bool[] calldata memberOf
    ) external onlyOwner {
        if (roleKeys.length != memberOf.length) {
            revert ArraysDifferentLength();
        }
        for (uint16 i; i < roleKeys.length; ++i) {
            roles[roleKeys[i]].members[module] = memberOf[i];
        }
        if (!isModuleEnabled(module)) {
            enableModule(module);
        }
        emit AssignRoles(module, roleKeys, memberOf);
    }

    /// @dev Sets the default role used for a module if it calls execTransactionFromModule() or execTransactionFromModuleReturnData().
    /// @param module Address of the module on which to set default role.
    /// @param roleKey Role to be set as default.
    function setDefaultRole(
        address module,
        bytes32 roleKey
    ) external onlyOwner {
        defaultRoles[module] = roleKey;
        emit SetDefaultRole(module, roleKey);
    }

    /// @dev Passes a transaction to the modifier.
    /// @param to Destination address of module transaction
    /// @param value Ether value of module transaction
    /// @param data Data payload of module transaction
    /// @param operation Operation type of module transaction
    /// @notice Can only be called by enabled modules
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) public override returns (bool success) {
        Consumption[] memory consumptions = _authorize(
            defaultRoles[msg.sender],
            to,
            value,
            data,
            operation
        );
        _flushPrepare(consumptions);
        success = exec(to, value, data, operation);
        _flushCommit(consumptions, success);
    }

    /// @dev Passes a transaction to the modifier, expects return data.
    /// @param to Destination address of module transaction
    /// @param value Ether value of module transaction
    /// @param data Data payload of module transaction
    /// @param operation Operation type of module transaction
    /// @notice Can only be called by enabled modules
    function execTransactionFromModuleReturnData(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) public override returns (bool success, bytes memory returnData) {
        Consumption[] memory consumptions = _authorize(
            defaultRoles[msg.sender],
            to,
            value,
            data,
            operation
        );
        _flushPrepare(consumptions);
        (success, returnData) = execAndReturnData(to, value, data, operation);
        _flushCommit(consumptions, success);
    }

    /// @dev Passes a transaction to the modifier assuming the specified role.
    /// @param to Destination address of module transaction
    /// @param value Ether value of module transaction
    /// @param data Data payload of module transaction
    /// @param operation Operation type of module transaction
    /// @param roleKey Identifier of the role to assume for this transaction
    /// @param shouldRevert Should the function revert on inner execution returning success false?
    /// @notice Can only be called by enabled modules
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    ) public returns (bool success) {
        Consumption[] memory consumptions = _authorize(
            roleKey,
            to,
            value,
            data,
            operation
        );
        _flushPrepare(consumptions);
        success = exec(to, value, data, operation);
        if (shouldRevert && !success) {
            revert ModuleTransactionFailed();
        }
        _flushCommit(consumptions, success);
    }

    /// @dev Passes a transaction to the modifier assuming the specified role. Expects return data.
    /// @param to Destination address of module transaction
    /// @param value Ether value of module transaction
    /// @param data Data payload of module transaction
    /// @param operation Operation type of module transaction
    /// @param roleKey Identifier of the role to assume for this transaction
    /// @param shouldRevert Should the function revert on inner execution returning success false?
    /// @notice Can only be called by enabled modules
    function execTransactionWithRoleReturnData(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    ) public returns (bool success, bytes memory returnData) {
        Consumption[] memory consumptions = _authorize(
            roleKey,
            to,
            value,
            data,
            operation
        );
        _flushPrepare(consumptions);
        (success, returnData) = execAndReturnData(to, value, data, operation);
        if (shouldRevert && !success) {
            revert ModuleTransactionFailed();
        }
        _flushCommit(consumptions, success);
    }
}


// File: contracts/Topology.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

import "./Types.sol";

/**
 * @title Topology - a library that provides helper functions for dealing with
 * the flat representation of conditions.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 */
library Topology {
    struct TypeTree {
        ParameterType paramType;
        TypeTree[] children;
    }

    struct Bounds {
        uint256 start;
        uint256 end;
        uint256 length;
    }

    function childrenBounds(
        ConditionFlat[] memory conditions
    ) internal pure returns (Bounds[] memory result) {
        uint256 count = conditions.length;
        assert(count > 0);

        // parents are breadth-first
        result = new Bounds[](count);
        result[0].start = type(uint256).max;

        // first item is the root
        for (uint256 i = 1; i < count; ) {
            result[i].start = type(uint256).max;
            Bounds memory parentBounds = result[conditions[i].parent];
            if (parentBounds.start == type(uint256).max) {
                parentBounds.start = i;
            }
            parentBounds.end = i + 1;
            parentBounds.length = parentBounds.end - parentBounds.start;
            unchecked {
                ++i;
            }
        }
    }

    function isInline(TypeTree memory node) internal pure returns (bool) {
        ParameterType paramType = node.paramType;
        if (paramType == ParameterType.Static) {
            return true;
        } else if (
            paramType == ParameterType.Dynamic ||
            paramType == ParameterType.Array ||
            paramType == ParameterType.Calldata ||
            paramType == ParameterType.AbiEncoded
        ) {
            return false;
        } else {
            uint256 length = node.children.length;

            for (uint256 i; i < length; ) {
                if (!isInline(node.children[i])) {
                    return false;
                }
                unchecked {
                    ++i;
                }
            }
            return true;
        }
    }

    function typeTree(
        Condition memory condition
    ) internal pure returns (TypeTree memory result) {
        if (
            condition.operator >= Operator.And &&
            condition.operator <= Operator.Nor
        ) {
            assert(condition.children.length > 0);
            return typeTree(condition.children[0]);
        }

        result.paramType = condition.paramType;
        if (condition.children.length > 0) {
            uint256 length = condition.paramType == ParameterType.Array
                ? 1
                : condition.children.length;
            result.children = new TypeTree[](length);

            for (uint256 i; i < length; ) {
                result.children[i] = typeTree(condition.children[i]);

                unchecked {
                    ++i;
                }
            }
        }
    }

    function typeTree(
        ConditionFlat[] memory conditions,
        uint256 index,
        Bounds[] memory bounds
    ) internal pure returns (TypeTree memory result) {
        ConditionFlat memory condition = conditions[index];
        if (
            condition.operator >= Operator.And &&
            condition.operator <= Operator.Nor
        ) {
            assert(bounds[index].length > 0);
            return typeTree(conditions, bounds[index].start, bounds);
        }

        result.paramType = condition.paramType;
        if (bounds[index].length > 0) {
            uint256 start = bounds[index].start;
            uint256 end = condition.paramType == ParameterType.Array
                ? bounds[index].start + 1
                : bounds[index].end;
            result.children = new TypeTree[](end - start);
            for (uint256 i = start; i < end; ) {
                result.children[i - start] = typeTree(conditions, i, bounds);
                unchecked {
                    ++i;
                }
            }
        }
    }
}


// File: contracts/Types.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

/**
 * @title Types - a file that contains all of the type definitions used throughout
 * the Zodiac Roles Mod.
 * @author Cristóvão Honorato - <cristovao.honorato@gnosis.io>
 * @author Jan-Felix Schwarz  - <jan-felix.schwarz@gnosis.io>
 */

enum ParameterType {
    None,
    Static,
    Dynamic,
    Tuple,
    Array,
    Calldata,
    AbiEncoded
}

enum Operator {
    // 00:    EMPTY EXPRESSION (default, always passes)
    //          paramType: Static / Dynamic / Tuple / Array
    //          ❓ children (only for paramType: Tuple / Array to describe their structure)
    //          🚫 compValue
    /* 00: */ Pass,
    // ------------------------------------------------------------
    // 01-04: LOGICAL EXPRESSIONS
    //          paramType: None
    //          ✅ children
    //          🚫 compValue
    /* 01: */ And,
    /* 02: */ Or,
    /* 03: */ Nor,
    /* 04: */ _Placeholder04,
    // ------------------------------------------------------------
    // 05-14: COMPLEX EXPRESSIONS
    //          paramType: Calldata / AbiEncoded / Tuple / Array,
    //          ✅ children
    //          🚫 compValue
    /* 05: */ Matches,
    /* 06: */ ArraySome,
    /* 07: */ ArrayEvery,
    /* 08: */ ArraySubset,
    /* 09: */ _Placeholder09,
    /* 10: */ _Placeholder10,
    /* 11: */ _Placeholder11,
    /* 12: */ _Placeholder12,
    /* 13: */ _Placeholder13,
    /* 14: */ _Placeholder14,
    // ------------------------------------------------------------
    // 15:    SPECIAL COMPARISON (without compValue)
    //          paramType: Static
    //          🚫 children
    //          🚫 compValue
    /* 15: */ EqualToAvatar,
    // ------------------------------------------------------------
    // 16-31: COMPARISON EXPRESSIONS
    //          paramType: Static / Dynamic / Tuple / Array
    //          ❓ children (only for paramType: Tuple / Array to describe their structure)
    //          ✅ compValue
    /* 16: */ EqualTo, // paramType: Static / Dynamic / Tuple / Array
    /* 17: */ GreaterThan, // paramType: Static
    /* 18: */ LessThan, // paramType: Static
    /* 19: */ SignedIntGreaterThan, // paramType: Static
    /* 20: */ SignedIntLessThan, // paramType: Static
    /* 21: */ Bitmask, // paramType: Static / Dynamic
    /* 22: */ Custom, // paramType: Static / Dynamic / Tuple / Array
    /* 23: */ _Placeholder23,
    /* 24: */ _Placeholder24,
    /* 25: */ _Placeholder25,
    /* 26: */ _Placeholder26,
    /* 27: */ _Placeholder27,
    /* 28: */ WithinAllowance, // paramType: Static
    /* 29: */ EtherWithinAllowance, // paramType: None
    /* 30: */ CallWithinAllowance, // paramType: None
    /* 31: */ _Placeholder31
}

enum ExecutionOptions {
    None,
    Send,
    DelegateCall,
    Both
}

enum Clearance {
    None,
    Target,
    Function
}

// This struct is a flattened version of Condition
// used for ABI encoding a scope config tree
// (ABI does not support recursive types)
struct ConditionFlat {
    uint8 parent;
    ParameterType paramType;
    Operator operator;
    bytes compValue;
}

struct Condition {
    ParameterType paramType;
    Operator operator;
    bytes32 compValue;
    Condition[] children;
}
struct ParameterPayload {
    uint256 location;
    uint256 size;
    ParameterPayload[] children;
}

struct TargetAddress {
    Clearance clearance;
    ExecutionOptions options;
}

struct Role {
    mapping(address => bool) members;
    mapping(address => TargetAddress) targets;
    mapping(bytes32 => bytes32) scopeConfig;
}

/// @notice The order of members in the `Allowance` struct is significant; members updated during accrual (`balance` and `timestamp`) should be stored in the same word.
/// @custom:member refill Amount added to balance after each period elapses.
/// @custom:member maxRefill Refilling stops when balance reaches this value.
/// @custom:member period Duration, in seconds, before a refill occurs. If set to 0, the allowance is for one-time use and won't be replenished.
/// @custom:member balance Remaining allowance available for use. Decreases with usage and increases after each refill by the specified refill amount.
/// @custom:member timestamp Timestamp when the last refill occurred.
struct Allowance {
    uint128 refill;
    uint128 maxRefill;
    uint64 period;
    uint128 balance;
    uint64 timestamp;
}

struct Consumption {
    bytes32 allowanceKey;
    uint128 balance;
    uint128 consumed;
}


// File: contracts/WriteOnce.sol
// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.17 <0.9.0;

interface ISingletonFactory {
    function deploy(
        bytes memory initCode,
        bytes32 salt
    ) external returns (address);
}

library WriteOnce {
    address public constant SINGLETON_FACTORY =
        0xce0042B868300000d44A59004Da54A005ffdcf9f;

    bytes32 public constant SALT =
        0x0000000000000000000000000000000000000000000000000000000000000000;

    /**
    @notice Stores `data` and returns `pointer` as key for later retrieval
    @dev The pointer is a contract address with `data` as code
    @param data to be written
    @return pointer Pointer to the written `data`
  */
    function store(bytes memory data) internal returns (address pointer) {
        bytes memory creationBytecode = creationBytecodeFor(data);
        pointer = addressFor(creationBytecode);

        uint256 size;
        assembly {
            size := extcodesize(pointer)
        }

        if (size == 0) {
            assert(
                pointer ==
                    ISingletonFactory(SINGLETON_FACTORY).deploy(
                        creationBytecode,
                        SALT
                    )
            );
        }
    }

    /**
    @notice Reads the contents of the `pointer` code as data, skips the first byte
    @dev The function is intended for reading pointers generated by `store`
    @param pointer to be read
    @return runtimeBytecode read from `pointer` contract
  */
    function load(
        address pointer
    ) internal view returns (bytes memory runtimeBytecode) {
        uint256 rawSize;
        assembly {
            rawSize := extcodesize(pointer)
        }
        assert(rawSize > 1);

        // jump over the prepended 00
        uint256 offset = 1;
        // don't count with the 00
        uint256 size = rawSize - 1;

        runtimeBytecode = new bytes(size);
        assembly {
            extcodecopy(pointer, add(runtimeBytecode, 32), offset, size)
        }
    }

    function addressFor(
        bytes memory creationBytecode
    ) private pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                SINGLETON_FACTORY,
                SALT,
                keccak256(creationBytecode)
            )
        );
        // get the right most 20 bytes
        return address(uint160(uint256(hash)));
    }

    /**
    @notice Generate a creation code that results on a contract with `data` as bytecode
    @param data the buffer to be stored
    @return creationBytecode (constructor) for new contract
    */
    function creationBytecodeFor(
        bytes memory data
    ) private pure returns (bytes memory) {
        /*
      0x00    0x63         0x63XXXXXX  PUSH4 _code.length  size
      0x01    0x80         0x80        DUP1                size size
      0x02    0x60         0x600e      PUSH1 14            14 size size
      0x03    0x60         0x6000      PUSH1 00            0 14 size size
      0x04    0x39         0x39        CODECOPY            size
      0x05    0x60         0x6000      PUSH1 00            0 size
      0x06    0xf3         0xf3        RETURN
      <CODE>
    */

        return
            abi.encodePacked(
                hex"63",
                uint32(data.length + 1),
                hex"80_60_0E_60_00_39_60_00_F3",
                // Prepend 00 to data so contract can't be called
                hex"00",
                data
            );
    }
}


