#!/usr/bin/env python3
# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import json
from argparse import REMAINDER, ArgumentParser, Namespace
from pathlib import Path
from typing import Optional, Set

from idb.cli import ClientCommand
from idb.common.command import CommandGroup
from idb.common.format import (
    human_format_installed_test_info,
    human_format_test_info,
    json_format_installed_test_info,
    json_format_test_info,
)
from idb.common.misc import get_env_with_idb_prefix
from idb.common.types import Client, CodeCoverageFormat, ExitWithCodeException


class XctestInstallCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Install an xctest"

    @property
    def name(self) -> str:
        return "install"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "test_bundle_path", help="Bundle path of the test bundle", type=str
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        async for install_response in client.install_xctest(args.test_bundle_path):
            if install_response.progress != 0.0 and not args.json:
                print("Installed {install_response.progress}%")
            elif args.json:
                print(
                    json.dumps(
                        {
                            "installedTestBundleId": install_response.name,
                            "uuid": install_response.uuid,
                        }
                    )
                )
            else:
                print(f"Installed: {install_response.name} {install_response.uuid}")


class XctestsListBundlesCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "List the installed test bundles"

    @property
    def name(self) -> str:
        return "list"

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        tests = await client.list_xctests()
        formatter = human_format_installed_test_info
        if args.json:
            formatter = json_format_installed_test_info
        for test in tests:
            print(formatter(test))


class XctestListTestsCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "List the tests inside an installed test bundle"

    @property
    def name(self) -> str:
        return "list-bundle"

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "test_bundle_id", help="Bundle id of the test bundle to list", type=str
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        self.add_parser_positional_arguments(parser)
        parser.add_argument(
            "--app-path",
            default=None,
            type=str,
            help="Path of the app of the test (needed for app tests)",
        )
        parser.add_argument(
            "--install",
            help="When this option is provided bundle_ids are assumed "
            "to be paths instead. They are installed before listing.",
            action="store_true",
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        if args.install:
            await self.install_bundles(args, client)
        app_path = args.app_path and str(Path(args.app_path).resolve(strict=True))
        tests = await client.list_test_bundle(
            test_bundle_id=args.test_bundle_id, app_path=app_path
        )
        if args.json:
            print(json.dumps(tests))
        else:
            print("\n".join(tests))

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        async for test in client.install_xctest(args.test_bundle_id):
            args.test_bundle_id = test.name


class CommonRunXcTestCommand(ClientCommand):
    @property
    def description(self) -> str:
        return (
            f"Run an installed {self.name} test. Will pass through"
            " any environment\nvariables prefixed with IDB_"
        )

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "test_bundle_id", help="Bundle id of the test to launch", type=str
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        self.add_parser_positional_arguments(parser)
        parser.add_argument(
            "--result-bundle-path",
            default=None,
            type=str,
            help="Path to save the result bundle",
        )
        parser.add_argument(
            "--timeout",
            help="The number of seconds to wait before the test times out. When the timeout is exceeded the test will exit and an attempt will be made to obtain a sample of the hung process",
            default=None,
            type=int,
        )
        parser.add_argument(
            "--report-activities",
            action="store_true",
            help="idb will report activity data emitted by your test bundle",
        )
        parser.add_argument(
            "--report-attachments",
            action="store_true",
            help="idb will report activity and attachment data emitted by your test bundle",
        )
        parser.add_argument(
            "--activities-output-path",
            help=(
                "When activity data is reported, "
                "data blobs will be saved to this location"
            ),
        )
        parser.add_argument(
            "--coverage-output-path",
            help="Outputs code coverage information. See --coverage-format option.",
        )
        parser.add_argument(
            "--coverage-format",
            choices=[str(key) for (key, _) in CodeCoverageFormat.__members__.items()],
            default="EXPORTED",
            help="Format for code coverage information: "
            "EXPORTED (default value) a file in JSON format as exported by `llvm-cov export`; "
            "RAW a folder containing the .profraw files as generated by the Test Bundle, Host App and/or Target App",
        )
        parser.add_argument(
            "--log-directory-path",
            default=None,
            type=str,
            help="Path to save the test logs collected",
        )
        parser.add_argument(
            "--wait-for-debugger",
            action="store_true",
            help="Suspend test run process to wait for a debugger to be attached. (Only supported by logic test).",
        )
        parser.add_argument(
            "--install",
            help="When this option is provided bundle_ids are assumed "
            "to be paths instead. They are installed before running.",
            action="store_true",
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        await super().run_with_client(args, client)
        if args.install:
            await self.install_bundles(args, client)
        tests_to_run = self.get_tests_to_run(args)
        tests_to_skip = self.get_tests_to_skip(args)
        app_bundle_id = args.app_bundle_id if hasattr(args, "app_bundle_id") else None
        test_host_app_bundle_id = (
            args.test_host_app_bundle_id
            if hasattr(args, "test_host_app_bundle_id")
            else None
        )
        arguments = getattr(args, "test_arguments", [])
        is_ui = args.run == "ui"
        is_logic = args.run == "logic"

        if args.wait_for_debugger and not is_logic:
            print(
                "--wait_for_debugger flag is only supported for logic tests. Default to False for app and ui tests."
            )

        formatter = json_format_test_info if args.json else human_format_test_info
        crashed_outside_test_case = False
        coverage_format = CodeCoverageFormat[args.coverage_format]

        async for test_result in client.run_xctest(
            test_bundle_id=args.test_bundle_id,
            app_bundle_id=app_bundle_id,
            test_host_app_bundle_id=test_host_app_bundle_id,
            is_ui_test=is_ui,
            is_logic_test=is_logic,
            tests_to_run=tests_to_run,
            tests_to_skip=tests_to_skip,
            timeout=args.timeout,
            env=get_env_with_idb_prefix(),
            args=arguments,
            result_bundle_path=args.result_bundle_path,
            report_activities=args.report_activities or args.report_attachments,
            report_attachments=args.report_attachments,
            activities_output_path=args.activities_output_path,
            coverage_output_path=args.coverage_output_path,
            coverage_format=coverage_format,
            log_directory_path=args.log_directory_path,
            wait_for_debugger=args.wait_for_debugger,
        ):
            print(formatter(test_result))
            crashed_outside_test_case = (
                crashed_outside_test_case or test_result.crashed_outside_test_case
            )
        if crashed_outside_test_case:
            raise ExitWithCodeException(3)

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        async for test in client.install_xctest(args.test_bundle_id):
            args.test_bundle_id = test.name

    def get_tests_to_run(self, args: Namespace) -> Optional[Set[str]]:
        return None

    def get_tests_to_skip(self, args: Namespace) -> Optional[Set[str]]:
        return None


class XctestRunAppCommand(CommonRunXcTestCommand):
    @property
    def name(self) -> str:
        return "app"

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_positional_arguments(parser)
        parser.add_argument(
            "app_bundle_id", help="Bundle id of the app to test", type=str
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "--tests-to-run",
            nargs="*",
            help="Run only these tests, \
            if not specified all tests are run. \
            Format: className/methodName",
        )
        parser.add_argument(
            "--tests-to-skip",
            nargs="*",
            help="Skip these tests, \
            has precedence over --tests-to-run. \
            Format: className/methodName",
        )
        parser.add_argument(
            "test_arguments",
            help="Arguments to start the test with",
            default=[],
            nargs=REMAINDER,
        )

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        await super().install_bundles(args, client)
        async for app in client.install(args.app_bundle_id):
            args.app_bundle_id = app.name

    def get_tests_to_run(self, args: Namespace) -> Optional[Set[str]]:
        return set(args.tests_to_run) if args.tests_to_run else None

    def get_tests_to_skip(self, args: Namespace) -> Optional[Set[str]]:
        return set(args.tests_to_skip) if args.tests_to_skip else None


class XctestRunUICommand(XctestRunAppCommand):
    @property
    def name(self) -> str:
        return "ui"

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_positional_arguments(parser)
        parser.add_argument(
            "test_host_app_bundle_id",
            help="Bundle id of the app that hosts ui test",
            type=str,
        )

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        await super().install_bundles(args, client)
        async for app in client.install(args.test_host_app_bundle_id):
            args.test_host_app_bundle_id = app.name


class XctestRunLogicCommand(CommonRunXcTestCommand):
    @property
    def name(self) -> str:
        return "logic"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "--test-to-run",
            nargs=1,
            help="Run only this test, \
            if not specified all tests are run. \
            Format: className/methodName",
        )
        parser.add_argument(
            "--tests-to-run",
            nargs="*",
            help="Run these tests only. \
            if not specified all tests are run. \
            Format: className/methodName",
        )

    def get_tests_to_run(self, args: Namespace) -> Optional[Set[str]]:
        if args.test_to_run:
            return set(args.test_to_run)
        if args.tests_to_run:
            tests = ""
            for test in args.tests_to_run:
                tests += test + ","
            tests = tests[:-1]
            # the companion is expecting a set of size one for the logic tests,
            # that is why we parse it here
            return {tests}
        return None


XctestRunCommand = CommandGroup(
    name="run",
    description=(
        "Run an installed xctest. Any environment variables of the form IDB_X\n"
        " will be passed through with the IDB_ prefix removed."
    ),
    commands=[
        XctestRunAppCommand(),
        XctestRunUICommand(),
        XctestRunLogicCommand(),
    ],
)
