import pytest
from tests.registry import CONTRACTS


@pytest.mark.parametrize("case", [pytest.param(case, id=case.id, marks=[getattr(pytest.mark, m) for m in case.marks])
                                  for case in CONTRACTS])
def test_bash(case, private_repo, command):
    command(case.argv, cwd=private_repo, timeout=case.timeout)
