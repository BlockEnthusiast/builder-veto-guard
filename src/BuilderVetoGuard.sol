// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title BuilderVetoGuard
/// @notice Safe transaction guard (Safe 1.3.0 / 1.4.1 / 1.5.0) and module guard (Safe 1.5.0)
///         that refuses to let its Safe transact inside a block built by a vetoed builder.
///
///         Two on-chain signals:
///
///         1. Fee recipient. `block.coinbase` is on the veto list. Titan Builder sets its own
///            address (titanbuilder.eth, 0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97) as the fee
///            recipient of every block it builds and pays the proposer in a last transaction.
///
///         2. Phylax marker. A watched Phylax Credible Registry marked the current block
///            (`lastCredibleBlock() == block.number`). Only builders whitelisted on the registry
///            can mark, and they mark before the protected calls of the same block, so a marker
///            ahead of this transaction means a Phylax builder built the block.
///
///         A guard revert reverts the whole `execTransaction`. The Safe nonce stays unused, so the
///         same signed transaction can land later in a block that is not vetoed.
///
///         Liveness: a transaction that only maintains the guard (`setGuard` / `setModuleGuard`
///         on the Safe, or any call to this contract) skips the registry signal, so a registry
///         that marks every block cannot lock the Safe. The fee-recipient veto applies to every
///         transaction, maintenance included.
///
///         Simulation: calls with `tx.gasprice == 0` pass. `eth_call` and `eth_estimateGas` run at
///         gas price 0 unless the caller sets one, and they see the latest block's coinbase, so
///         without this every wallet and Safe UI simulation would fail while the latest block is
///         Titan's. Every transaction mined on Ethereum mainnet pays a base fee above zero, so the
///         exemption never applies on chain there. Do not use this guard on a chain where zero-price
///         transactions can be mined.
contract BuilderVetoGuard {
    enum Operation {
        Call,
        DelegateCall
    }

    /// @notice The only account allowed to change the lists: the Safe this guard serves.
    address public immutable SAFE;

    /// @notice Upper bound on watched registries; each costs one bounded staticcall per transaction.
    uint256 public constant MAX_REGISTRIES = 4;

    /// @notice Gas forwarded to each registry read. A read that fails, runs out of gas, or returns
    ///         anything but one word counts as "not marked" (the fee-recipient veto still applies).
    uint256 public constant REGISTRY_READ_GAS = 30_000;

    bytes4 private constant LAST_CREDIBLE_BLOCK = 0x0cb140e6; // lastCredibleBlock()
    bytes4 private constant SET_GUARD = 0xe19a9dd9; // setGuard(address)
    bytes4 private constant SET_MODULE_GUARD = 0xe068df37; // setModuleGuard(address), Safe 1.5.0

    bytes4 private constant TRANSACTION_GUARD_ID = 0xe6d7a83a; // checkTransaction ^ checkAfterExecution
    bytes4 private constant MODULE_GUARD_ID = 0x58401ed8; // checkModuleTransaction ^ checkAfterModuleExecution
    bytes4 private constant ERC165_ID = 0x01ffc9a7;

    address[] private _coinbases;
    mapping(address => uint256) private _coinbaseSlot; // index + 1; 0 = not vetoed
    address[] private _registries;
    mapping(address => uint256) private _registrySlot; // index + 1; 0 = not watched

    event CoinbaseVetoSet(address indexed coinbase, bool vetoed);
    event RegistryWatchSet(address indexed registry, bool watched);

    error OnlySafe();
    error ZeroAddress();
    error TooManyRegistries();
    error VetoedBuilder(address coinbase);
    error VetoedCredibleBlock(address registry, uint256 blockNumber);

    modifier onlySafe() {
        if (msg.sender != SAFE) revert OnlySafe();
        _;
    }

    /// @param safe The Safe that will install this guard and may edit its lists.
    /// @param coinbases Initial fee recipients to veto (Titan: 0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97).
    /// @param registries Initial Phylax Credible Registries to watch (live since block 26,358,669:
    ///        0xbac71fe7a8c78f49eeb2d33b250988224796af70).
    constructor(address safe, address[] memory coinbases, address[] memory registries) {
        if (safe == address(0)) revert ZeroAddress();
        SAFE = safe;
        for (uint256 i; i < coinbases.length; ++i) {
            _setCoinbase(coinbases[i], true);
        }
        for (uint256 i; i < registries.length; ++i) {
            _setRegistry(registries[i], true);
        }
    }

    // ------------------------------------------------------------------ Safe hooks

    /// @notice Safe calls this before every owner-signed `execTransaction`.
    /// @dev `signatures` is decoded to memory: a second calldata slice pushes the ABI decoder past
    ///      the 16-slot stack limit without via-IR. Same selector either way.
    function checkTransaction(
        address to,
        uint256,
        bytes calldata data,
        Operation operation,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory,
        address
    ) external view {
        _enforce(to, data, operation);
    }

    function checkAfterExecution(bytes32, bool) external pure {}

    /// @notice Safe 1.5.0 calls this before every module transaction once installed with
    ///         `setModuleGuard`. Safe 1.3.0 and 1.4.1 have no module guard: their modules bypass it.
    function checkModuleTransaction(address to, uint256, bytes calldata data, Operation operation, address)
        external
        view
        returns (bytes32)
    {
        _enforce(to, data, operation);
        return bytes32(0);
    }

    function checkAfterModuleExecution(bytes32, bool) external pure {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == TRANSACTION_GUARD_ID || interfaceId == MODULE_GUARD_ID || interfaceId == ERC165_ID;
    }

    // ------------------------------------------------------------------ configuration

    /// @notice Add or remove a vetoed fee recipient. Only the Safe, through a Safe transaction.
    function setCoinbaseVeto(address coinbase, bool vetoed) external onlySafe {
        _setCoinbase(coinbase, vetoed);
    }

    /// @notice Watch or stop watching a Phylax Credible Registry. Phylax has replaced its mainnet
    ///         registry before (0x5924…4672 until block 26,349,396), so the Safe can follow it.
    function setRegistryWatch(address registry, bool watched) external onlySafe {
        _setRegistry(registry, watched);
    }

    // ------------------------------------------------------------------ views

    function vetoedCoinbases() external view returns (address[] memory) {
        return _coinbases;
    }

    function watchedRegistries() external view returns (address[] memory) {
        return _registries;
    }

    function isVetoedCoinbase(address coinbase) external view returns (bool) {
        return _coinbaseSlot[coinbase] != 0;
    }

    function isWatchedRegistry(address registry) external view returns (bool) {
        return _registrySlot[registry] != 0;
    }

    // ------------------------------------------------------------------ internals

    function _enforce(address to, bytes calldata data, Operation operation) private view {
        if (tx.gasprice == 0) return; // simulation only, see contract notice
        if (_coinbaseSlot[block.coinbase] != 0) revert VetoedBuilder(block.coinbase);
        if (_isGuardMaintenance(to, data, operation)) return;
        uint256 n = _registries.length;
        for (uint256 i; i < n; ++i) {
            address registry = _registries[i];
            if (_markedThisBlock(registry)) revert VetoedCredibleBlock(registry, block.number);
        }
    }

    function _isGuardMaintenance(address to, bytes calldata data, Operation operation) private view returns (bool) {
        if (operation != Operation.Call) return false;
        if (to == address(this)) return true;
        if (to != SAFE || data.length < 4) return false;
        bytes4 selector = bytes4(data[:4]);
        return selector == SET_GUARD || selector == SET_MODULE_GUARD;
    }

    function _markedThisBlock(address registry) private view returns (bool marked) {
        bytes4 selector = LAST_CREDIBLE_BLOCK;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            let ok := staticcall(REGISTRY_READ_GAS, registry, 0x00, 0x04, 0x00, 0x20)
            marked := and(and(ok, eq(returndatasize(), 0x20)), eq(mload(0x00), number()))
        }
    }

    function _setCoinbase(address coinbase, bool vetoed) private {
        if (coinbase == address(0)) revert ZeroAddress();
        if (_toggle(_coinbases, _coinbaseSlot, coinbase, vetoed)) emit CoinbaseVetoSet(coinbase, vetoed);
    }

    function _setRegistry(address registry, bool watched) private {
        if (registry == address(0)) revert ZeroAddress();
        if (_toggle(_registries, _registrySlot, registry, watched)) {
            if (_registries.length > MAX_REGISTRIES) revert TooManyRegistries();
            emit RegistryWatchSet(registry, watched);
        }
    }

    /// @dev Swap-and-pop set. Returns false when the entry was already in the requested state.
    function _toggle(address[] storage list, mapping(address => uint256) storage slot, address a, bool on)
        private
        returns (bool changed)
    {
        uint256 s = slot[a];
        if (on) {
            if (s != 0) return false;
            list.push(a);
            slot[a] = list.length;
            return true;
        }
        if (s == 0) return false;
        address last = list[list.length - 1];
        list[s - 1] = last;
        slot[last] = s;
        list.pop();
        delete slot[a];
        return true;
    }
}
