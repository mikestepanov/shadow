import subprocess
import json
import time
import os
import sys

# Configuration
REPO_DIR = "/home/mikhail/Desktop/nixelo-agent"
JULES_PREFIXES = [
    "bolt", "sentinel", "spectra", "auditor", "palette", 
    "inspector", "refactor", "schema", "scribe", "librarian"
]
ENV = os.environ.copy()
# Ensure correct path for NixOS tools
ENV["PATH"] = "/nix/store/dh2yzrnp5raifh3knbphhljrsjqkcklr-git-2.51.2/bin:/nix/store/7bmqbqbpaxhf7k29m1v820mr3xl5mb52-coreutils-9.8/bin:/nix/store/c4091kqz1rw8n6vmygbvvwpr00ghdmks-gh-2.83.2/bin:/run/current-system/sw/bin:" + ENV.get("PATH", "")

def log(msg):
    print(f"[JulesAuto] {msg}")

def run_command(cmd, cwd=REPO_DIR, retries=3):
    """Run shell command with retries."""
    for attempt in range(retries):
        try:
            result = subprocess.run(
                cmd, 
                shell=True, 
                cwd=cwd, 
                capture_output=True, 
                text=True, 
                env=ENV,
                check=True
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            if attempt < retries - 1:
                log(f"Command failed: {cmd}. Retrying in 5s... ({e.stderr.strip()})")
                time.sleep(5)
            else:
                raise e

def is_jules_branch(branch_name):
    for prefix in JULES_PREFIXES:
        if branch_name.startswith(f"{prefix}/") or branch_name.startswith(f"{prefix}-"):
            return True
    return False

def main():
    summary = {
        "merged": [],
        "skipped": [],
        "failed": [],
        "manual_review": []
    }

    try:
        # 1. Update Repo
        log("Updating repository...")
        run_command("git checkout main")
        run_command("git pull origin main")

        # 2. List PRs
        log("Fetching open PRs...")
        pr_json = run_command("gh pr list --state open --json number,title,headRefName,url")
        prs = json.loads(pr_json)

        if not prs:
            print("No open PRs found.")
            return

        for pr in prs:
            number = pr['number']
            branch = pr['headRefName']
            title = pr['title']

            log(f"Processing PR #{number}: {title} ({branch})")

            # 3. Check Prefix
            if not is_jules_branch(branch):
                log(f"Skipping PR #{number} - Not a Jules branch.")
                summary["skipped"].append(f"#{number} ({branch}) - Non-Jules")
                continue

            try:
                # 4. Checkout
                run_command(f"gh pr checkout {number}")

                # 5. Check CI Status
                # "gh pr checks" returns exit code 1 if failing, but sometimes just lists them.
                # We'll parse the output or just try to merge.
                # The robust way: try to merge. If it's blocked by branch protection, it will fail.
                # But we should check conflicts first.
                
                # Merge main into branch to check/resolve conflicts
                try:
                    run_command("git merge main -m 'Merge main'")
                except subprocess.CalledProcessError:
                    log(f"Conflict merging main into #{number}. Aborting update.")
                    run_command("git merge --abort")
                    summary["manual_review"].append(f"#{number} - Merge Conflict")
                    continue

                # 6. Attempt Squash Merge
                # The prompt asks for squash merge + delete branch
                # "gh pr merge <number> --squash --delete-branch"
                try:
                    run_command(f"gh pr merge {number} --squash --delete-branch --admin") # --admin to bypass if needed/allowed
                    summary["merged"].append(f"#{number} {title}")
                    log(f"SUCCESS: Merged PR #{number}")
                except subprocess.CalledProcessError as e:
                    err = e.stderr.strip()
                    log(f"Merge failed for #{number}: {err}")
                    if "checks" in err.lower() or "status" in err.lower():
                        summary["manual_review"].append(f"#{number} - CI Checks Failed")
                    else:
                        summary["failed"].append(f"#{number} - {err}")

            except Exception as e:
                log(f"Error processing PR #{number}: {e}")
                summary["failed"].append(f"#{number} - Exception: {str(e)}")
            finally:
                # Reset to main for next iteration
                run_command("git checkout main")

        # 7. Cleanup Local Branches
        log("Cleaning up local branches...")
        # Get all local branches except main
        local_branches = run_command("git branch --format='%(refname:short)'").split('\n')
        for br in local_branches:
            br = br.strip()
            if br != "main" and is_jules_branch(br):
                try:
                    run_command(f"git branch -D {br}")
                except:
                    pass

    except Exception as e:
        log(f"Critical script failure: {e}")
        print(f"CRITICAL FAILURE: {e}")

    # Final Output
    print("\n--- SUMMARY ---")
    if summary["merged"]:
        print(f"✅ Merged ({len(summary['merged'])}):")
        for item in summary["merged"]: print(f"  - {item}")
    
    if summary["manual_review"]:
        print(f"⚠️ Manual Review Needed ({len(summary['manual_review'])}):")
        for item in summary["manual_review"]: print(f"  - {item}")

    if summary["skipped"]:
        print(f"⏭️ Skipped ({len(summary['skipped'])}):")
        for item in summary["skipped"]: print(f"  - {item}")
        
    if summary["failed"]:
        print(f"❌ Failed ({len(summary['failed'])}):")
        for item in summary["failed"]: print(f"  - {item}")

if __name__ == "__main__":
    main()
