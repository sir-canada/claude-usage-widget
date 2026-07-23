.pragma library

// How close a reset has to be before we count it down second-by-second.
var IMMINENT_SEC = 90;

// Compact "time until reset" -> "3d21h", "4h59m", "7m", "47s", "—"
//
// Under IMMINENT_SEC we drop to bare seconds: the reset epoch is precise to
// the sub-second, and "now"/"1m" is a useless thing to stare at while you're
// waiting for the quota to come back. Callers pair this with a 1s tick so the
// last minute and a half actually ticks.
function fmtDuration(sec) {
  if (sec === null || sec === undefined || isNaN(sec)) return "—";
  sec = Math.max(0, Math.floor(sec));
  if (sec < IMMINENT_SEC) return sec + "s";
  var m = Math.floor(sec / 60);
  var h = Math.floor(m / 60);
  var d = Math.floor(h / 24);
  if (d > 0) return d + "d" + (h % 24) + "h";
  if (h > 0) return h + "h" + (m % 60) + "m";
  return m + "m";
}

// Wall-clock time the reset lands. Far out (>24h) it needs the day to mean
// anything -> "Mon Jul 20, 18:59"; today/tonight the clock alone is clearer
// -> "22:59".
function fmtResetWhen(epoch, remainSec) {
  if (!epoch) return "";
  var dt = new Date(epoch * 1000);
  return Qt.formatDateTime(dt, remainSec > 86400 ? "ddd MMM d, HH:mm" : "HH:mm");
}

// Bare age for the footer's "Updated <i>76s</i> ago" line. Exact seconds is
// the point here — the daemon polls every ~110s, so "1m" would hide whether
// the data is 61s or 119s old. Stays in seconds for the first hour.
function fmtAge(sec) {
  if (sec === null || sec === undefined || isNaN(sec)) return "—";
  sec = Math.max(0, Math.floor(sec));
  if (sec < 3600) return sec + "s";
  var h = Math.floor(sec / 3600);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// Idle-for badge on session rows -> "1d3h", "2h14m", "34m". Empty under a
// minute: too fresh to matter, and hiding it avoids a flickery "0m".
function fmtIdle(sec) {
  if (sec === null || sec === undefined || isNaN(sec)) return "";
  sec = Math.max(0, Math.floor(sec));
  var m = Math.floor(sec / 60);
  if (m < 1) return "";
  var h = Math.floor(m / 60);
  var d = Math.floor(h / 24);
  if (d > 0) return d + "d" + (h % 24) + "h";
  if (h > 0) return h + "h" + (m % 60) + "m";
  return m + "m";
}

// "just now", "42s ago", "3m ago", "2h ago", "1d ago"
function fmtAgo(sec) {
  if (sec === null || sec === undefined || isNaN(sec)) return "";
  sec = Math.max(0, Math.floor(sec));
  if (sec < 5) return "just now";
  if (sec < 60) return sec + "s ago";
  var m = Math.floor(sec / 60);
  if (m < 60) return m + "m ago";
  var h = Math.floor(m / 60);
  if (h < 24) return h + "h ago";
  return Math.floor(h / 24) + "d ago";
}
