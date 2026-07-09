.pragma library

// Compact "time until reset" -> "3d21h", "4h59m", "7m", "now", "—"
function fmtDuration(sec) {
  if (sec === null || sec === undefined || isNaN(sec)) return "—";
  sec = Math.max(0, Math.floor(sec));
  if (sec < 60) return "now";
  var m = Math.floor(sec / 60);
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
