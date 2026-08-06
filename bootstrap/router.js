// One URL, routed by User-Agent. Deploy as a Cloudflare Worker on the install host.
//
//   Linux/macOS : curl -fsSL https://dott.er/i | sh -s viktorashi
//   Windows     : irm https://dott.er/i | iex
//
// The URL is identical. Only the fetcher/interpreter wrapper differs — and that part
// CANNOT be unified, because the set of interpreters present on both a bare Linux and a
// bare Windows install is empty. See docs/DESIGN.md.
//
// An explicit extension always wins, so /i.sh and /i.ps1 stay directly addressable
// (needed for CI, for debugging, and for anyone who dislikes UA sniffing).

const SRC = "https://raw.githubusercontent.com/viktorashi/dotter/viktorashi/bootstrap";

// PowerShell 5.1 IWR/IRM sends "... WindowsPowerShell/5.1.x"; PowerShell 7+ sends
// "... PowerShell/7.x". Match both, plus a plain "windows" fallback.
const IS_POWERSHELL = /powershell|windowsnt|microsoft-cryptoapi/i;

function pick(pathname, ua) {
  if (pathname.endsWith(".ps1")) return "install.ps1";
  if (pathname.endsWith(".sh")) return "install.sh";
  return IS_POWERSHELL.test(ua) ? "install.ps1" : "install.sh";
}

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    const ua = request.headers.get("user-agent") || "";
    const file = pick(pathname, ua);

    const upstream = await fetch(`${SRC}/${file}`, {
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    if (!upstream.ok) {
      return new Response(`could not fetch ${file}\n`, { status: 502 });
    }

    return new Response(upstream.body, {
      headers: {
        // text/plain so a browser shows the script instead of downloading it —
        // people should be able to read what they are about to pipe into a shell.
        "content-type": "text/plain; charset=utf-8",
        "x-install-script": file,
        "cache-control": "public, max-age=300",
      },
    });
  },
};

// ---------------------------------------------------------------------------
// nginx equivalent, if self-hosting instead:
//
//   map $http_user_agent $install_script {
//       default              "install.sh";
//       "~*powershell"       "install.ps1";
//       "~*windowsnt"        "install.ps1";
//   }
//
//   location = /i     { default_type text/plain; alias /srv/bootstrap/$install_script; }
//   location = /i.sh  { default_type text/plain; alias /srv/bootstrap/install.sh; }
//   location = /i.ps1 { default_type text/plain; alias /srv/bootstrap/install.ps1; }
// ---------------------------------------------------------------------------

export { pick, IS_POWERSHELL };
