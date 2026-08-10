use anyhow::{Context, Result};
use std::process::Command;

/// Splits an input string of the form `<repo>[:<branch>]` into its parts.
///
/// Handles the SSH edge-case: `git@github.com:user/repo.git` has exactly one
/// `:` that is part of the URL itself, not a branch separator. We detect this
/// by checking for `@` + a single colon.
fn parse_clone_input(input: &str) -> (&str, Option<&str>) {
    // Bare SSH URL (git@host:user/repo.git) — single colon belongs to the URL.
    if input.contains('@') && input.matches(':').count() == 1 {
        return (input, None);
    }

    if let Some(idx) = input.rfind(':') {
        let branch = &input[idx + 1..];
        // If the suffix starts with `//` we've landed on the `https:` colon.
        if !branch.is_empty() && !branch.starts_with("//") {
            return (&input[..idx], Some(branch));
        }
    }

    (input, None)
}

pub fn get_clone_url(input: Option<&str>) -> Result<String> {
    let input = match input {
        Some(s) if !s.is_empty() => s,
        _ => {
            // Default to whoami
            let user = whoami::username().unwrap_or_else(|_| "unknown".to_string());
            return Ok(format!("https://github.com/{}/dotfiles.git", user));
        }
    };

    if input.contains("://") || input.contains('@') {
        return Ok(input.to_string());
    }

    if input.contains('/') {
        return Ok(format!("https://github.com/{}.git", input));
    }

    Ok(format!("https://github.com/{}/dotfiles.git", input))
}

pub fn run_clone(input: Option<&str>) -> Result<std::path::PathBuf> {
    let (repo_part, branch) = match input {
        Some(s) => parse_clone_input(s),
        None => ("", None),
    };
    let url = get_clone_url(if repo_part.is_empty() { None } else { Some(repo_part) })?;
    match branch {
        Some(b) => println!("Cloning {} (branch: {})...", url, b),
        None => println!("Cloning {}...", url),
    }

    // Create a temporary directory
    let temp_dir = std::env::temp_dir().join(format!("dotter_clone_{}", std::process::id()));
    if temp_dir.exists() {
        std::fs::remove_dir_all(&temp_dir).context("remove existing temp clone dir")?;
    }

    let mut cmd = Command::new("git");
    cmd.arg("clone");
    if let Some(b) = branch {
        cmd.arg("-b").arg(b);
    }
    cmd.arg(&url).arg(&temp_dir);

    let status = cmd.status().context("Failed to run git clone")?;

    if !status.success() {
        anyhow::bail!("git clone failed with status {}", status);
    }

    // Now find where it should go
    // For now, we will default to ~/.dotfiles if dotter.toml is not present
    let mut target_dir = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("Could not find home directory"))?
        .join(".dotfiles");

    // Try to read dotter.toml from the cloned repo
    let dotter_toml_path = temp_dir.join("dotter.toml");
    if dotter_toml_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&dotter_toml_path) {
            if let Ok(parsed) = content.parse::<toml::Value>() {
                if let Some(repo) = parsed.get("repo").and_then(|r| r.as_str()) {
                    let expanded = shellexpand::tilde(repo).into_owned();
                    target_dir = std::path::PathBuf::from(expanded);
                }
            }
        }
    }

    if target_dir.exists() {
        anyhow::bail!("Target repository directory {} already exists. Cannot move clone.", target_dir.display());
    }

    if let Some(parent) = target_dir.parent() {
        std::fs::create_dir_all(parent).context("create parent directory of target")?;
    }

    std::fs::rename(&temp_dir, &target_dir).context("move cloned repo to target location")?;
    println!("Successfully cloned repository to {}", target_dir.display());
    
    // Change working directory to the new repo
    std::env::set_current_dir(&target_dir).context("change working directory to new repo")?;

    Ok(target_dir)
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn parse_plain_username() {
        assert_eq!(parse_clone_input("supercuber"), ("supercuber", None));
    }

    #[test]
    fn parse_username_with_branch() {
        assert_eq!(
            parse_clone_input("supercuber:dev"),
            ("supercuber", Some("dev"))
        );
    }

    #[test]
    fn parse_user_repo() {
        assert_eq!(
            parse_clone_input("supercuber/dotfiles"),
            ("supercuber/dotfiles", None)
        );
    }

    #[test]
    fn parse_user_repo_with_branch() {
        assert_eq!(
            parse_clone_input("supercuber/dotfiles:main"),
            ("supercuber/dotfiles", Some("main"))
        );
    }

    #[test]
    fn parse_https_url_no_branch() {
        assert_eq!(
            parse_clone_input("https://github.com/user/repo.git"),
            ("https://github.com/user/repo.git", None)
        );
    }

    #[test]
    fn parse_https_url_with_branch() {
        assert_eq!(
            parse_clone_input("https://github.com/user/repo.git:nightly"),
            ("https://github.com/user/repo.git", Some("nightly"))
        );
    }

    #[test]
    fn parse_ssh_url_no_branch() {
        // The single colon belongs to the SSH URL — no branch.
        assert_eq!(
            parse_clone_input("git@github.com:user/repo.git"),
            ("git@github.com:user/repo.git", None)
        );
    }

    #[test]
    fn parse_ssh_url_with_branch() {
        // Two colons: first belongs to SSH, second separates branch.
        assert_eq!(
            parse_clone_input("git@github.com:user/repo.git:nightly"),
            ("git@github.com:user/repo.git", Some("nightly"))
        );
    }

    #[test]
    fn parse_branch_with_slashes() {
        assert_eq!(
            parse_clone_input("supercuber:feat/new-machine"),
            ("supercuber", Some("feat/new-machine"))
        );
    }

    #[test]
    fn url_from_username() {
        assert_eq!(
            get_clone_url(Some("supercuber")).unwrap(),
            "https://github.com/supercuber/dotfiles.git"
        );
    }

    #[test]
    fn url_from_user_repo() {
        assert_eq!(
            get_clone_url(Some("supercuber/configs")).unwrap(),
            "https://github.com/supercuber/configs.git"
        );
    }

    #[test]
    fn url_passthrough_https() {
        let url = "https://gitlab.com/me/dots.git";
        assert_eq!(get_clone_url(Some(url)).unwrap(), url);
    }

    #[test]
    fn url_passthrough_ssh() {
        let url = "git@github.com:user/repo.git";
        assert_eq!(get_clone_url(Some(url)).unwrap(), url);
    }
}
