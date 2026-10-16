#!/bin/bash
mkdir -p ~/.ssh
echo "$WPE_SSHG_KEY_PRIVATE" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
ssh-keyscan -H ${WPE_ENV}.ssh.wpengine.net >> ~/.ssh/known_hosts

RETRY_NOTES=""

run_remote() {
ssh -i ~/.ssh/id_rsa -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 ${WPE_ENV}@${WPE_ENV}.ssh.wpengine.net <<EOF
cd ~/sites/${WPE_ENV}/
mkdir -p _wpeprivate
LOG=_wpeprivate/cron-run.log
ERR=_wpeprivate/cron-run-error.log
FAILLOG=_wpeprivate/failures-and-retries.log
LOGDIR=_wpeprivate/logs
mkdir -p \$LOGDIR

# Weekly archive: when the ISO week changes, gzip the finished week's logs into
# \$LOGDIR and start fresh; archives older than 8 weeks are deleted.
WEEK=\$(date +%G-W%V)
MARK=\$LOGDIR/.current-week
PREV=\$(cat \$MARK 2>/dev/null)
if [ -n "\$PREV" ] && [ "\$PREV" != "\$WEEK" ]; then
  for f in \$LOG \$ERR \$FAILLOG; do
    if [ -s \$f ]; then
      gzip -c \$f > \$LOGDIR/\$(basename \$f .log)-\$PREV.log.gz && : > \$f
    fi
  done
fi
echo \$WEEK > \$MARK
find \$LOGDIR -name '*.log.gz' -mtime +56 -delete

# SSH failures/retries from earlier attempts of this run (recorded locally, written now that we're connected)
$RETRY_NOTES
echo "---\$(date) ---" >> \$LOG
echo "GitHub Run: https://github.com/$GHA_REPO/actions/runs/$GHA_RUN_ID" >> \$LOG

# Pre details
# wp core version >> \$LOG 2>> \$ERR

for url in \$(wp site list --field=url --archived=0 --spam=0 --deleted=0); do
  echo "Site: \$url" >> \$LOG
  # wp cron event list --url="\$url" >> \$LOG 2>> \$ERR
  wp cron event run --due-now --url="\$url" --exec='ini_set("display_errors", "0"); error_reporting(E_ALL & ~E_WARNING & ~E_NOTICE & ~E_DEPRECATED);' >> \$LOG 2>> \$ERR \
    || echo "FAILED: \$url" >> \$ERR
done

# Keep logs bounded: if over the cap, keep the last N bytes and drop the first
# (partial) line so the file always starts on a whole line
trim() {
  if [ \$(wc -c < \$1) -gt \$2 ]; then
    tail -c \$2 \$1 | tail -n +2 > \$1.tmp && mv \$1.tmp \$1
  fi
}
trim \$LOG 10485760
trim \$ERR 10485760
trim \$FAILLOG 10485760
EOF
}

# ssh exits 255 on connection-level failures (dropped/refused/reset); retry those only.
# Re-running is safe: --due-now only runs events that are actually due.
for attempt in 1 2 3; do
  run_remote && exit 0
  rc=$?
  [ $rc -ne 255 ] && exit $rc
  echo "SSH connection failed (attempt $attempt/3, exit $rc), retrying in 20s..." >&2
  RETRY_NOTES="$RETRY_NOTES
echo '---$(date) ---' >> \$FAILLOG
echo 'GitHub Run: https://github.com/$GHA_REPO/actions/runs/$GHA_RUN_ID' >> \$FAILLOG
echo 'SSH connection failed (attempt $attempt/3, exit $rc), retried' >> \$FAILLOG"
  sleep 20
done
echo "SSH failed after 3 attempts; no connection to write failures-and-retries.log" >&2
exit 255
