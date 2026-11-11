// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BuilderVetoGuard} from "../src/BuilderVetoGuard.sol";

import {GnosisSafe as Safe130} from "safe130/GnosisSafe.sol";
import {GnosisSafeProxy as Proxy130} from "safe130/proxies/GnosisSafeProxy.sol";
import {Guard as Guard130} from "safe130/base/GuardManager.sol";
import {Safe as Safe141} from "safe141/Safe.sol";
import {SafeProxy as Proxy141} from "safe141/proxies/SafeProxy.sol";
import {Guard as Guard141} from "safe141/base/GuardManager.sol";
import {Safe as Safe150} from "safe150/Safe.sol";
import {SafeProxy as Proxy150} from "safe150/proxies/SafeProxy.sol";
import {ITransactionGuard} from "safe150/base/GuardManager.sol";
import {IModuleGuard} from "safe150/base/ModuleManager.sol";

/// The parts of the Safe ABI the tests use. Identical across 1.3.0, 1.4.1 and 1.5.0
/// (`Enum.Operation` encodes as uint8).
interface ISafeLike {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool);

    function nonce() external view returns (uint256);
    function enableModule(address module) external;
    function setGuard(address guard) external;
    function setModuleGuard(address guard) external;
}

contract Counter {
    uint256 public n;

    function bump() external {
        ++n;
    }
}

contract MockRegistry {
    uint256 public lastCredibleBlock;

    function mark() external {
        lastCredibleBlock = block.number;
    }
}

contract RevertingRegistry {
    fallback() external {
        revert("down");
    }
}

contract ShortReplyRegistry {
    fallback() external {
        assembly {
            mstore(0, number())
            return(0, 16)
        }
    }
}

contract LongReplyRegistry {
    fallback() external {
        assembly {
            mstore(0, number())
            mstore(32, 1)
            return(0, 64)
        }
    }
}

contract GasBurnRegistry {
    fallback() external {
        while (true) {}
    }
}

contract BuilderVetoGuardTest is Test {
    address constant TITAN = 0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97;
    address constant QUASAR = address(0x0a5a);
    bytes32 constant GUARD_SLOT = keccak256("guard_manager.guard.address");
    bytes32 constant MODULE_GUARD_SLOT = keccak256("module_manager.module_guard.address");

    address owner = makeAddr("owner");
    Counter counter;
    MockRegistry registry;

    ISafeLike[3] safes;
    BuilderVetoGuard[3] guards;
    string[3] labels = ["1.3.0", "1.4.1", "1.5.0"];

    function setUp() public {
        vm.txGasPrice(1 gwei); // a real transaction; 0 is the simulation path
        vm.coinbase(QUASAR);
        vm.roll(1_000);
        counter = new Counter();
        registry = new MockRegistry();

        safes[0] = ISafeLike(address(new Proxy130(address(new Safe130()))));
        safes[1] = ISafeLike(address(new Proxy141(address(new Safe141()))));
        safes[2] = ISafeLike(payable(address(new Proxy150(address(new Safe150())))));

        address[] memory owners = new address[](1);
        owners[0] = owner;
        address[] memory cbs = new address[](1);
        cbs[0] = TITAN;
        address[] memory regs = new address[](1);
        regs[0] = address(registry);

        for (uint256 i; i < 3; ++i) {
            ISafeLike s = safes[i];
            s.setup(owners, 1, address(0), "", address(0), address(0), 0, payable(address(0)));
            guards[i] = new BuilderVetoGuard(address(s), cbs, regs);
            _exec(s, address(s), abi.encodeCall(ISafeLike.setGuard, (address(guards[i]))), 0);
            assertEq(_guardOf(s), address(guards[i]), labels[i]);
        }
        // Safe 1.5.0: this test contract is a module, and the guard also guards modules.
        _exec(safes[2], address(safes[2]), abi.encodeCall(ISafeLike.enableModule, (address(this))), 0);
        _exec(safes[2], address(safes[2]), abi.encodeCall(ISafeLike.setModuleGuard, (address(guards[2]))), 0);
        assertEq(address(uint160(uint256(vm.load(address(safes[2]), MODULE_GUARD_SLOT)))), address(guards[2]));
    }

    // ------------------------------------------------------------ helpers

    function _sig() internal view returns (bytes memory) {
        // pre-validated signature: msg.sender is the owner
        return abi.encodePacked(uint256(uint160(owner)), uint256(0), uint8(1));
    }

    function _exec(ISafeLike s, address to, bytes memory data, uint8 op) internal returns (bool ok) {
        bytes memory sig = _sig();
        vm.prank(owner);
        ok = s.execTransaction(to, 0, data, op, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function _bump(ISafeLike s) internal returns (bool) {
        return _exec(s, address(counter), abi.encodeCall(Counter.bump, ()), 0);
    }

    function _guardOf(ISafeLike s) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(s), GUARD_SLOT))));
    }

    function _nextBlock(address coinbase) internal {
        vm.roll(block.number + 1);
        vm.coinbase(coinbase);
    }

    // ------------------------------------------------------------ interface

    function test_interfaceIdsMatchSafeSources() public view {
        assertEq(type(Guard130).interfaceId, bytes4(0xe6d7a83a));
        assertEq(type(Guard141).interfaceId, bytes4(0xe6d7a83a));
        assertEq(type(ITransactionGuard).interfaceId, bytes4(0xe6d7a83a));
        assertEq(type(IModuleGuard).interfaceId, bytes4(0x58401ed8));
        assertTrue(guards[0].supportsInterface(0xe6d7a83a));
        assertTrue(guards[0].supportsInterface(0x58401ed8));
        assertTrue(guards[0].supportsInterface(0x01ffc9a7));
        assertFalse(guards[0].supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------ fee-recipient veto

    function test_titanBlockReverts_nonceUnused_thenLandsInNextBlock() public {
        for (uint256 i; i < 3; ++i) {
            ISafeLike s = safes[i];
            _nextBlock(TITAN);
            uint256 nonce = s.nonce();
            uint256 n = counter.n();
            vm.expectRevert(abi.encodeWithSelector(BuilderVetoGuard.VetoedBuilder.selector, TITAN));
            _bump(s);
            assertEq(s.nonce(), nonce, labels[i]);
            assertEq(counter.n(), n, labels[i]);

            _nextBlock(QUASAR);
            assertTrue(_bump(s), labels[i]);
            assertEq(s.nonce(), nonce + 1, labels[i]);
            assertEq(counter.n(), n + 1, labels[i]);
        }
    }

    function testFuzz_anyOtherBuilderPasses(address coinbase) public {
        vm.assume(coinbase != TITAN);
        for (uint256 i; i < 3; ++i) {
            _nextBlock(coinbase);
            assertTrue(_bump(safes[i]), labels[i]);
        }
    }

    // ------------------------------------------------------------ Phylax marker

    function test_markedBlockReverts_unmarkedNextBlockPasses() public {
        for (uint256 i; i < 3; ++i) {
            ISafeLike s = safes[i];
            _nextBlock(QUASAR); // a builder Titan could spoof as; the marker still catches it
            registry.mark();
            vm.expectRevert(
                abi.encodeWithSelector(BuilderVetoGuard.VetoedCredibleBlock.selector, address(registry), block.number)
            );
            _bump(s);

            _nextBlock(QUASAR); // marker from the previous block does not count
            assertTrue(_bump(s), labels[i]);
        }
    }

    function test_brokenRegistriesFailOpen() public {
        address[5] memory bad = [
            address(new RevertingRegistry()),
            address(new ShortReplyRegistry()),
            address(new LongReplyRegistry()),
            address(new GasBurnRegistry()),
            makeAddr("eoa-registry")
        ];
        for (uint256 i; i < 3; ++i) {
            ISafeLike s = safes[i];
            BuilderVetoGuard g = guards[i];
            _nextBlock(QUASAR);
            // swap the healthy registry out so four bad ones fit under MAX_REGISTRIES
            _exec(s, address(g), abi.encodeCall(BuilderVetoGuard.setRegistryWatch, (address(registry), false)), 0);
            for (uint256 k; k < 4; ++k) {
                _exec(s, address(g), abi.encodeCall(BuilderVetoGuard.setRegistryWatch, (bad[k], true)), 0);
            }
            _nextBlock(QUASAR);
            assertTrue(_bump(s), labels[i]);
            _exec(s, address(g), abi.encodeCall(BuilderVetoGuard.setRegistryWatch, (bad[3], false)), 0);
            _exec(s, address(g), abi.encodeCall(BuilderVetoGuard.setRegistryWatch, (bad[4], true)), 0);
            assertTrue(_bump(s), labels[i]);
            // the fee-recipient veto still applies
            _nextBlock(TITAN);
            vm.expectRevert(abi.encodeWithSelector(BuilderVetoGuard.VetoedBuilder.selector, TITAN));
            _bump(s);
        }
    }

    // ------------------------------------------------------------ simulation

    function test_zeroGasPriceSimulationPasses() public {
        for (uint256 i; i < 3; ++i) {
            _nextBlock(TITAN);
            registry.mark();
            vm.txGasPrice(0);
            assertTrue(_bump(safes[i]), labels[i]);
            vm.txGasPrice(1 gwei);
            vm.expectRevert(abi.encodeWithSelector(BuilderVetoGuard.VetoedBuilder.selector, TITAN));
            _bump(safes[i]);
        }
    }

    // ------------------------------------------------------------ liveness

    function test_guardRemovalSkipsRegistryButNotFeeRecipient() public {
        for (uint256 i; i < 3; ++i) {
            ISafeLike s = safes[i];
            BuilderVetoGuard g = guards[i];

            // a registry that marks every block cannot lock the Safe
            _nextBlock(QUASAR);
            registry.mark();
            assertTrue(
                _exec(s, address(g), abi.encodeCall(BuilderVetoGuard.setCoinbaseVeto, (address(0xbeef), true)), 0)
            );
            assertTrue(_exec(s, address(s), abi.encodeCall(ISafeLike.setGuard, (address(0))), 0), labels[i]);
            assertEq(_guardOf(s), address(0), labels[i]);

            _nextBlock(QUASAR);
            _exec(s, address(s), abi.encodeCall(ISafeLike.setGuard, (address(g))), 0);

            // Titan cannot build even the removal
            _nextBlock(TITAN);
            vm.expectRevert(abi.encodeWithSelector(BuilderVetoGuard.VetoedBuilder.selector, TITAN));
            _exec(s, address(s), abi.encodeCall(ISafeLike.setGuard, (address(0))), 0);
            assertEq(_guardOf(s), address(g), labels[i]);
        }
    }

    function test_maintenanceExemptionIsNarrow() public {
        ISafeLike s = safes[0];
        BuilderVetoGuard g = guards[0];
        _nextBlock(QUASAR);
        registry.mark();
        bytes memory err =
            abi.encodeWithSelector(BuilderVetoGuard.VetoedCredibleBlock.selector, address(registry), block.number);

        // delegatecall to the guard is not maintenance
        vm.expectRevert(err);
        _exec(s, address(g), abi.encodeCall(BuilderVetoGuard.setCoinbaseVeto, (address(0xbeef), true)), 1);
        // other self-calls on the Safe are not maintenance
        vm.expectRevert(err);
        _exec(s, address(s), abi.encodeCall(ISafeLike.enableModule, (address(0xbeef))), 0);
        // short calldata to the Safe is not maintenance
        vm.expectRevert(err);
        _exec(s, address(s), hex"e19a9d", 0);
    }

    // ------------------------------------------------------------ Safe 1.5.0 module guard

    function test_moduleGuard150() public {
        ISafeLike s = safes[2];
        bytes memory bump = abi.encodeCall(Counter.bump, ());

        _nextBlock(TITAN);
        vm.expectRevert(abi.encodeWithSelector(BuilderVetoGuard.VetoedBuilder.selector, TITAN));
        s.execTransactionFromModule(address(counter), 0, bump, 0);

        _nextBlock(QUASAR);
        registry.mark();
        vm.expectRevert(
            abi.encodeWithSelector(BuilderVetoGuard.VetoedCredibleBlock.selector, address(registry), block.number)
        );
        s.execTransactionFromModule(address(counter), 0, bump, 0);

        _nextBlock(QUASAR);
        uint256 n = counter.n();
        assertTrue(s.execTransactionFromModule(address(counter), 0, bump, 0));
        assertEq(counter.n(), n + 1);
    }

    // ------------------------------------------------------------ configuration

    function test_onlySafeConfigures() public {
        BuilderVetoGuard g = guards[0];
        vm.expectRevert(BuilderVetoGuard.OnlySafe.selector);
        g.setCoinbaseVeto(address(1), true);
        vm.expectRevert(BuilderVetoGuard.OnlySafe.selector);
        vm.prank(owner); // an owner acting alone is not the Safe
        g.setRegistryWatch(address(1), true);
    }

    function test_listsSwapAndPop() public {
        BuilderVetoGuard g = guards[0];
        vm.startPrank(address(safes[0]));
        g.setCoinbaseVeto(address(0xA), true);
        g.setCoinbaseVeto(address(0xB), true);
        g.setCoinbaseVeto(address(0xA), true); // no-op
        g.setCoinbaseVeto(TITAN, false);
        g.setCoinbaseVeto(TITAN, false); // no-op
        vm.stopPrank();

        address[] memory cbs = g.vetoedCoinbases();
        assertEq(cbs.length, 2);
        assertEq(cbs[0], address(0xB));
        assertEq(cbs[1], address(0xA));
        assertFalse(g.isVetoedCoinbase(TITAN));
        assertTrue(g.isVetoedCoinbase(address(0xA)));

        vm.startPrank(address(safes[0]));
        g.setRegistryWatch(address(0x1), true);
        g.setRegistryWatch(address(0x2), true);
        g.setRegistryWatch(address(0x3), true);
        vm.expectRevert(BuilderVetoGuard.TooManyRegistries.selector);
        g.setRegistryWatch(address(0x4), true);
        vm.expectRevert(BuilderVetoGuard.ZeroAddress.selector);
        g.setCoinbaseVeto(address(0), true);
        vm.stopPrank();
        assertEq(g.watchedRegistries().length, 4);
    }

    function test_constructorChecks() public {
        address[] memory none = new address[](0);
        vm.expectRevert(BuilderVetoGuard.ZeroAddress.selector);
        new BuilderVetoGuard(address(0), none, none);

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = address(uint160(i + 1));
        }
        vm.expectRevert(BuilderVetoGuard.TooManyRegistries.selector);
        new BuilderVetoGuard(address(1), none, five);
    }
}
