use anyhow::{Context, Result};
use std::process::Command;

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
    let url = get_clone_url(input)?;
    println!("Cloning {}...", url);

    // Create a temporary directory
    let temp_dir = std::env::temp_dir().join(format!("dotter_clone_{}", std::process::id()));
    if temp_dir.exists() {
        std::fs::remove_dir_all(&temp_dir).context("remove existing temp clone dir")?;
    }

    let status = Command::new("git")
        .arg("clone")
        .arg(&url)
        .arg(&temp_dir)
        .status()
        .context("Failed to run git clone")?;

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
