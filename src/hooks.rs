use anyhow::{Context, Result};
use handlebars::Handlebars;

use std::path::Path;
use std::process::Child;
use std::process::Command;

use crate::filesystem::{Filesystem, RealFilesystem};

pub(crate) fn run_hook(
    location: &Path,
    cache_dir: &Path,
    handlebars: &Handlebars<'_>,
    variables: &crate::config::Variables,
) -> Result<()> {
    let win_sibling = if cfg!(windows) && location.extension().is_some_and(|e| e == "sh") {
        // Prefer .ps1 over .bat on Windows
        let ps1_candidate = location.with_extension("ps1");
        let bat_candidate = location.with_extension("bat");
        if ps1_candidate.exists() {
            debug!("Using hook file {:?} on windows", ps1_candidate);
            Some(ps1_candidate)
        } else if bat_candidate.exists() {
            debug!("Using hook file {:?} on windows", bat_candidate);
            Some(bat_candidate)
        } else {
            None
        }
    } else {
        None
    };
    let location: &Path = win_sibling.as_deref().unwrap_or(location);

    if !location.exists() {
        debug!("Hook file at {:?} missing", location);
        return Ok(());
    }

    let mut script_file = cache_dir.join(location);
    if cfg!(windows) && location.extension().is_none_or(|e| e != "ps1") {
        script_file.set_extension("bat");
    }

    debug!("Rendering script {:?} -> {:?}", location, script_file);
    let mut fs = RealFilesystem::new(false);
    crate::actions::perform_template_deploy(
        location,
        &script_file,
        None,
        &mut fs,
        handlebars,
        variables,
    )
    .context("deploy script")?;
    fs.copy_permissions(location, &script_file, &None)
        .context("copy permissions from source to cache")?;

    debug!("Running script file");
    let mut child = run_script_file(&script_file)?;

    anyhow::ensure!(
        child.wait().context("wait for child shell")?.success(),
        "subshell returned error"
    );

    Ok(())
}

pub(crate) fn run_package_hook(
    hook: &crate::config::Hook,
    cache_dir: &Path,
    handlebars: &Handlebars<'_>,
    variables: &crate::config::Variables,
) -> Result<()> {
    match hook {
        crate::config::Hook::Command { command, shell } => {
            debug!("Running command: {}", command);
            let mut child = if let Some(shell_args) = shell {
                anyhow::ensure!(!shell_args.is_empty(), "hook shell array must not be empty");
                let (program, prefix_args) = shell_args.split_first().unwrap();
                Command::new(program)
                    .args(prefix_args)
                    .arg(command)
                    .spawn()
                    .with_context(|| format!("spawn custom shell {:?}", program))?
            } else if cfg!(windows) {
                Command::new("cmd")
                    .args(["/C", command])
                    .spawn()
                    .context("spawn cmd")?
            } else {
                Command::new("sh")
                    .args(["-c", command])
                    .spawn()
                    .context("spawn sh")?
            };
            anyhow::ensure!(
                child.wait().context("wait for hook command")?.success(),
                "hook command returned error"
            );
            Ok(())
        }
        crate::config::Hook::File(location) => run_hook(location, cache_dir, handlebars, variables),
    }
}

#[cfg(unix)]
fn run_script_file(script: &Path) -> Result<Child> {
    use std::os::unix::fs::PermissionsExt;

    let permissions = script.metadata()?.permissions();
    if !script.is_dir() && permissions.mode() & 0o111 != 0 {
        Command::new(script).spawn().context("spawn script file")
    } else {
        Command::new("sh")
            .arg(script)
            .spawn()
            .context("spawn shell")
    }
}

#[cfg(windows)]
fn run_script_file(script: &Path) -> Result<Child> {
    if script.extension().is_some_and(|e| e == "ps1") {
        Command::new("powershell")
            .args(["-ExecutionPolicy", "Bypass", "-File"])
            .arg(script)
            .spawn()
            .context("spawn powershell")
    } else {
        Command::new(script).spawn().context("spawn batch file")
    }
}
