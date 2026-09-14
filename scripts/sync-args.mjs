import assert from "node:assert/strict";

const commitPattern = /^[0-9a-f]{40}$/;

function requireCommit(value, label) {
  assert(
    typeof value === "string" && commitPattern.test(value),
    `${label} must be a full lowercase Git commit SHA`,
  );
  return value;
}

export function parseSyncArgs(args, checkedInPublicSdkCommit) {
  let check = false;
  let ifPublished = false;
  let explicitCommit;
  let publicSdkCommitOverridden = false;
  let publicSdkCommit = requireCommit(
    checkedInPublicSdkCommit,
    "checked-in public SDK commit",
  );

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    switch (argument) {
      case "--check":
        assert(!check, "--check may be specified only once");
        check = true;
        break;
      case "--if-published":
        assert(!ifPublished, "--if-published may be specified only once");
        ifPublished = true;
        break;
      case "--commit":
        assert(explicitCommit === undefined, "--commit may be specified only once");
        explicitCommit = requireCommit(args[index + 1], "--commit");
        index += 1;
        break;
      case "--public-sdk-commit":
        assert(
          !publicSdkCommitOverridden,
          "--public-sdk-commit may be specified only once",
        );
        publicSdkCommitOverridden = true;
        publicSdkCommit = requireCommit(
          args[index + 1],
          "--public-sdk-commit",
        );
        index += 1;
        break;
      default:
        assert.fail(`unknown sync argument: ${argument}`);
    }
  }

  const modes = Number(check) + Number(ifPublished) + Number(explicitCommit !== undefined);
  assert(modes <= 1, "--check, --if-published, and --commit are mutually exclusive");

  return {
    check,
    explicitCommit,
    ifPublished,
    publicSdkCommit,
  };
}
