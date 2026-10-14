#!/bin/bash
mkdir -p ~/.ssh
echo "$WPE_SSHG_KEY_PRIVATE" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
ssh-keyscan -H ${WPE_ENV}.ssh.wpengine.net >> ~/.ssh/known_hosts

ssh -i ~/.ssh/id_rsa ${WPE_ENV}@${WPE_ENV}.ssh.wpengine.net <<EOF
cd ~/sites/${WPE_ENV}/
mkdir -p _wpeprivate
LOG=_wpeprivate/cron-run.log
ERR=_wpeprivate/cron-run-error.log
LOGDIR=_wpeprivate/logs
mkdir -p \$LOGDIR

# Weekly archive: when the ISO week changes, gzip the finished week's logs into
# \$LOGDIR and start fresh; archives older than 8 weeks are deleted.
WEEK=\$(date +%G-W%V)
MARK=\$LOGDIR/.current-week
PREV=\$(cat \$MARK 2>/dev/null)
if [ -n "\$PREV" ] && [ "\$PREV" != "\$WEEK" ]; then
  for f in \$LOG \$ERR; do
    if [ -s \$f ]; then
      gzip -c \$f > \$LOGDIR/\$(basename \$f .log)-\$PREV.log.gz && : > \$f
    fi
  done
fi
echo \$WEEK > \$MARK
find \$LOGDIR -name '*.log.gz' -mtime +56 -delete

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
trim \$ERR 2097152
EOF
