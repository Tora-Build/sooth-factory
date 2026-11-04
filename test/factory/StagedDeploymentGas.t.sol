// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {FactoryFixture} from "./FactoryFixture.sol";
import {NodeTypes} from "../../src/factory/NodeTypes.sol";
import {NodeDeployer} from "../../src/factory/NodeDeployer.sol";

interface IStagedFactory {
    function beginNode(NodeTypes.Request calldata request)
        external
        returns (bytes32 id, address deployer);
    function completeNode(NodeTypes.Request calldata request)
        external
        returns (bytes32 id, NodeTypes.Addresses memory addresses);
    function pendingDeployer(bytes32 id) external view returns (address);
}

/// @notice Independent stage gas bounds. Fixture release publication is setup;
/// neither deployment call can borrow unused gas from another transaction.
contract StagedDeploymentGasTest is FactoryFixture {
    uint256 private constant EXECUTION_BUDGET = 16_000_000;
    uint256 private constant TRANSACTION_CAP = 16_777_216;

    function test_EachStageFitsCapAndOnlyCompleteNodeActivates() public {
        NodeTypes.Request memory request = _request(admin, keccak256("independent gas"));
        _approve(request);
        (address predicted, NodeTypes.Addresses memory addresses) =
            factory.predictNode(request);
        bytes memory result = _capped(
            abi.encodeCall(IStagedFactory.beginNode, (request)),
            "begin node execution gas"
        );
        (bytes32 id, address deployer) = abi.decode(result, (bytes32, address));
        assertEq(deployer, predicted);
        assertEq(IStagedFactory(address(factory)).pendingDeployer(id), predicted);
        assertEq(factory.nodeDeployer(id), address(0));
        assertEq(factory.nodeCount(), 0);
        assertGt(addresses.roles.code.length, 0);
        assertGt(addresses.book.code.length, 0);
        assertGt(addresses.amm.code.length, 0);
        assertGt(addresses.positionManager.code.length, 0);
        assertEq(addresses.ammVault.code.length, 0);
        assertEq(addresses.bookVault.code.length, 0);
        assertEq(addresses.marketFactory.code.length, 0);
        assertEq(stable.balanceOf(addresses.book), 0);
        assertEq(stable.balanceOf(addresses.amm), 0);

        result = _capped(
            abi.encodeCall(IStagedFactory.completeNode, (request)),
            "complete node execution gas"
        );
        (bytes32 activatedId, NodeTypes.Addresses memory actual) =
            abi.decode(result, (bytes32, NodeTypes.Addresses));
        assertEq(activatedId, id);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(addresses)));
        assertEq(factory.nodeDeployer(id), deployer);
        assertEq(IStagedFactory(address(factory)).pendingDeployer(id), address(0));
        assertEq(factory.nodeCount(), 1);
        assertTrue(NodeDeployer(deployer).verifyWiring());
    }

    function _capped(bytes memory data, string memory label)
        private
        returns (bytes memory result)
    {
        // Forty gas per byte bounds both ordinary calldata pricing and its
        // higher calldata floor. This deliberately overcounts every zero byte.
        uint256 intrinsicBudget = 21_000 + data.length * 40;
        assertLt(EXECUTION_BUDGET + intrinsicBudget, TRANSACTION_CAP);
        vm.prank(admin);
        uint256 startGas = gasleft();
        bool success;
        (success, result) = address(factory).call{gas: EXECUTION_BUDGET}(data);
        uint256 used = startGas - gasleft();
        emit log_named_uint(label, used);
        assertTrue(success, "deployment stage exceeded gas budget or reverted");
        assertLt(used + intrinsicBudget, TRANSACTION_CAP);
    }
}
