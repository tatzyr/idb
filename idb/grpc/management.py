#!/usr/bin/env python3
# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import asyncio
import logging
import os
import signal
from typing import AsyncGenerator, Dict, List, Optional

from idb.common.companion import Companion, CompanionServerConfig
from idb.common.companion_set import CompanionSet
from idb.common.constants import BASE_IDB_FILE_PATH
from idb.common.logging import log_call
from idb.common.types import (
    ClientManager as ClientManagerBase,
    CompanionInfo,
    OnlyFilter,
    ConnectionDestination,
    DomainSocketAddress,
    IdbException,
    TargetType,
    TargetDescription,
    TCPAddress,
)
from idb.grpc.client import Client
from idb.grpc.target import merge_connected_targets
from idb.utils.contextlib import asynccontextmanager


async def _local_target_type(companion: Companion, udid: str) -> TargetType:
    if udid == "mac":
        return TargetType.MAC
    targets = {
        target.udid: target for target in await companion.list_targets(only=None)
    }
    target = targets.get(udid)
    if target is None:
        raise IdbException(
            f"Cannot spawn companion for {udid}, no matching target in available udids {targets.keys()}"
        )
    return target.target_type


class ClientManager(ClientManagerBase):
    def __init__(
        self,
        companion_path: Optional[str] = None,
        device_set_path: Optional[str] = None,
        prune_dead_companion: bool = True,
        logger: Optional[logging.Logger] = None,
    ) -> None:
        os.makedirs(BASE_IDB_FILE_PATH, exist_ok=True)
        self._logger: logging.Logger = (
            logger if logger else logging.getLogger("idb_grpc_client")
        )
        self._companion_set = CompanionSet(logger=self._logger)
        self._companion: Optional[Companion] = (
            Companion(
                companion_path=companion_path,
                device_set_path=device_set_path,
                logger=self._logger,
            )
            if companion_path is not None
            else None
        )
        self._prune_dead_companion = prune_dead_companion

    async def _spawn_companion_server(self, udid: str) -> CompanionInfo:
        companion = self._companion
        if companion is None:
            raise IdbException(
                f"Cannot spawn companion for {udid}, no companion executable"
            )
        target_type = await _local_target_type(companion=companion, udid=udid)
        path = os.path.join(BASE_IDB_FILE_PATH, f"{udid}_companion.sock")
        self._logger.info(f"Attempting to spawn a companion at {path} for {udid}")
        process = await companion.spawn_domain_sock_server(
            config=CompanionServerConfig(
                udid=udid,
                only=target_type,
                log_file_path=None,
                cwd=None,
                tmp_path=None,
                reparent=True,
            ),
            path=path,
        )
        self._logger.info(f"Companion at {path} spawned for {udid}")
        companion_info = CompanionInfo(
            address=DomainSocketAddress(path=path),
            udid=udid,
            is_local=True,
            pid=process.pid,
        )
        await self._companion_set.add_companion(companion_info)
        return companion_info

    async def _companion_to_target(
        self, companion: CompanionInfo
    ) -> Optional[TargetDescription]:
        try:
            async with Client.build(
                address=companion.address, logger=self._logger
            ) as client:
                return await client.describe()
        except Exception:
            if not self._prune_dead_companion:
                self._logger.warning(
                    f"Failed to describe {companion}, but not removing it"
                )
                return None
            self._logger.warning(f"Failed to describe {companion}, removing it")
            await self._companion_set.remove_companion(companion.address)
            return None

    @asynccontextmanager
    async def from_udid(self, udid: Optional[str]) -> AsyncGenerator[Client, None]:
        companions = {
            companion.udid: companion
            for companion in await self._companion_set.get_companions()
        }
        if udid is not None and udid in companions:
            companion = companions[udid]
            self._logger.debug(f"Got existing companion {companion} for udid {udid}")
        elif udid is not None:
            self._logger.debug(f"No running companion for {udid}, spawning one")
            companion = await self._spawn_companion_server(udid=udid)
        elif len(companions) == 1:
            self._logger.debug(
                "No udid provided, and there is a sole companion, using it"
            )
            companion = list(companions.values())[0]
        elif len(companions) == 0:
            raise IdbException(
                "No udid provided and there no companions, unclear which target to run against. Please specify a UDID"
            )
        else:
            raise IdbException(
                f"No udid provided and there are multiple companions to run against {companions.keys()}. Please specify a UDID unclear which target to run against"
            )
        async with Client.build(
            address=companion.address,
            logger=self._logger,
        ) as client:
            self._logger.debug(f"Constructed client for companion {companion}")
            yield client

    @log_call()
    async def list_targets(
        self, only: Optional[OnlyFilter] = None
    ) -> List[TargetDescription]:
        async def _list_local_targets() -> List[TargetDescription]:
            companion = self._companion
            if companion is None:
                return []
            return await companion.list_targets(only=only)

        (companions, local_targets) = await asyncio.gather(
            self._companion_set.get_companions(),
            _list_local_targets(),
        )
        connected_targets = [
            target
            for target in (
                await asyncio.gather(
                    *(
                        self._companion_to_target(companion=companion)
                        for companion in companions
                    )
                )
            )
            if target is not None
        ]
        return merge_connected_targets(
            local_targets=local_targets, connected_targets=connected_targets
        )

    @log_call()
    async def connect(
        self,
        destination: ConnectionDestination,
        metadata: Optional[Dict[str, str]] = None,
    ) -> CompanionInfo:
        self._logger.debug(f"Connecting directly to {destination} with meta {metadata}")
        if isinstance(destination, TCPAddress) or isinstance(
            destination, DomainSocketAddress
        ):
            async with Client.build(address=destination, logger=self._logger) as client:
                companion = client.companion
            self._logger.debug(f"Connected directly to {companion}")
            await self._companion_set.add_companion(companion)
            return companion
        else:
            companion = await self._spawn_companion_server(udid=destination)
            if companion:
                return companion
            else:
                raise IdbException(f"can't find target for udid {destination}")

    @log_call()
    async def disconnect(self, destination: ConnectionDestination) -> None:
        await self._companion_set.remove_companion(destination)

    @log_call()
    async def kill(self) -> None:
        cleared = await self._companion_set.clear()
        self._logger.info(f"Cleared stored companion set {cleared}")
        for companion in cleared:
            pid = companion.pid
            if pid is None:
                continue
            self._logger.info(f"Killing spawned companion {companion}")
            os.kill(pid, signal.SIGKILL)
