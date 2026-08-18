// daemon.c —— DeepSeek Harness 守护(macOS 专用,~1.3MB RSS)
// 最简设计:单一端口(DSH_RT_PORT,默认 3080,全链路自动匹配,无硬编码双端口)。
//   dsh 未运行 → 伺服引导页(任意路径);PWA 打开引导页 → 自动 /wake → dsh 在内部端口启动。
//   dsh 运行中 → 双向透传;PWA 关闭 → 连接归零 N 秒(DSH_RT_IDLE_STOP_SECS,默认 60)→ 自动停止 dsh。
//   dsh 内部端口:启动时自动挑选空闲端口,写入 RT_STATE/dsh.json。
//   dsh 位置:install.sh 装好运行时后写 RT_HOME/run.json({"node":...,"dsh":...}),守护直接 exec。
// 端点(守护自身处理,不透传):
//   GET  /health               → {"dsh":bool,"port":int,"pid":int}
//   POST /wake                 → 未运行则拉起 dsh(直启 node + 官方 dsh web)
//   POST /stop                 → 停止 dsh(SIGTERM → 超时 SIGKILL)
//   GET  /manifest.webmanifest → PWA manifest(Safari「添加到程序坞」用;仅 dsh 未运行时有意义)
// 构建: clang -O2 -o daemon daemon.c(CI/install.sh 编译)
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char RT_HOME[1024], RT_STATE[1024], LOG_DIR[1024], LOG_FILE[1100], BOOT_PAGE[16384];
static char DSH_JSON[1100], PID_FILE[1100], DSH_HOME[1024];
static char NODE_BIN[1024], DSH_BIN[1024];
static int PORT = 3080, IDLE_STOP = 60;

static const char *env_or(const char *k, const char *d) {
  const char *v = getenv(k);
  return (v && v[0]) ? v : d;
}

static void build_paths(void) {
  const char *home = env_or("HOME", "/");
  const char *rh = env_or("DSH_RT_HOME", "");
  const char *rs = env_or("DSH_RT_STATE", "");
  snprintf(RT_HOME, sizeof RT_HOME, "%s", rh[0] ? rh : "");
  if (!RT_HOME[0]) snprintf(RT_HOME, sizeof RT_HOME, "%s/.local/share/dsh-runtime", home);
  if (!rs[0]) { char s[1024]; snprintf(s, sizeof s, "%s/.local/state/dsh-runtime", home); rs = s; }
  snprintf(RT_STATE, sizeof RT_STATE, "%s", rs);
  snprintf(LOG_DIR, sizeof LOG_DIR, "%s/logs", rs);
  snprintf(LOG_FILE, sizeof LOG_FILE, "%s/dsh.log", LOG_DIR);
  snprintf(DSH_JSON, sizeof DSH_JSON, "%s/dsh.json", rs);
  snprintf(PID_FILE, sizeof PID_FILE, "%s/dsh.pid", rs);
  snprintf(DSH_HOME, sizeof DSH_HOME, "%s", env_or("DSH_HOME", ""));
  if (!DSH_HOME[0]) snprintf(DSH_HOME, sizeof DSH_HOME, "%s/.dsh", home);
  const char *p = getenv("DSH_RT_PORT");
  if (p && *p) PORT = atoi(p);
  p = getenv("DSH_RT_IDLE_STOP_SECS");
  if (p && *p) IDLE_STOP = atoi(p);
  mkdir(LOG_DIR, 0755);
}

// ---------- run.json(install.sh 写入:运行时位置) ----------
static void extract_str(const char *b, const char *key, char *out, size_t cap) {
  char pat[64]; snprintf(pat, sizeof pat, "\"%s\"", key);
  const char *k = strstr(b, pat);
  if (!k) { out[0] = 0; return; }
  const char *q = strchr(k + strlen(pat), ':');
  q = q ? strchr(q, '"') : NULL;
  if (!q) { out[0] = 0; return; }
  q++;
  const char *e = strchr(q, '"');
  size_t l = e ? (size_t)(e - q) : strlen(q);
  if (l >= cap) l = cap - 1;
  memcpy(out, q, l); out[l] = 0;
}

static void read_run(void) {
  char p[1100]; snprintf(p, sizeof p, "%s/run.json", RT_HOME);
  int fd = open(p, O_RDONLY);
  if (fd < 0) return;
  char b[4096]; ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return;
  b[n] = 0;
  extract_str(b, "node", NODE_BIN, sizeof NODE_BIN);
  extract_str(b, "dsh", DSH_BIN, sizeof DSH_BIN);
}

// ---------- dsh 状态(端口来自 dsh.json,由守护启动 dsh 时写入) ----------
static int dsh_port = 0;

static int read_state_port(void) {
  int fd = open(DSH_JSON, O_RDONLY);
  if (fd < 0) return 0;
  char b[256]; ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return 0;
  b[n] = 0;
  char *q = strstr(b, "\"port\"");
  if (!q) return 0;
  q = strchr(q + 6, ':');
  if (!q) return 0;
  return atoi(q + 1);
}

static int read_pid(void) {
  int fd = open(PID_FILE, O_RDONLY);
  if (fd < 0) return 0;
  char b[32]; ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return 0;
  b[n] = 0;
  return atoi(b);
}

static int dsh_up(void) {
  if (dsh_port <= 0) return 0;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return 0;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(dsh_port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int ok = connect(s, (struct sockaddr *)&a, sizeof a) == 0;
  close(s);
  return ok;
}

// 挑选空闲端口作为 dsh 内部端口(启动前调用)
static int pick_port(void) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return 0;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = 0;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return 0; }
  socklen_t al = sizeof a;
  getsockname(s, (struct sockaddr *)&a, &al);
  int p = ntohs(a.sin_port);
  close(s);
  return p;
}

// ---------- dsh 启停(直启,无 wrapper) ----------
// 非连接子进程(dsh 本体)不计入活跃连接,否则 waitpid 会把它们误算为连接关闭
static pid_t spawn_pids[8];
static int spawn_n = 0;
static int is_spawn(pid_t p) { for (int i = 0; i < spawn_n; i++) if (spawn_pids[i] == p) return 1; return 0; }

static void spawn_dsh(void) {
  int port = pick_port();
  if (port <= 0) return;
  pid_t pid = fork();
  if (pid != 0) {
    if (spawn_n < 8) spawn_pids[spawn_n++] = pid;
    char j[64]; snprintf(j, sizeof j, "{\"port\":%d}\n", port);
    int fd = open(DSH_JSON, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { write(fd, j, strlen(j)); close(fd); }
    char ps[32]; snprintf(ps, sizeof ps, "%d\n", pid);
    fd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { write(fd, ps, strlen(ps)); close(fd); }
    return;
  }
  setsid();
  int lfd = open(LOG_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (lfd >= 0) { dup2(lfd, 1); dup2(lfd, 2); close(lfd); }
  setenv("DSH_HOME", DSH_HOME, 1);
  setenv("DSH_TELEMETRY_DISABLED", "1", 1);
  char port_s[16]; snprintf(port_s, sizeof port_s, "%d", port);
  execl(NODE_BIN, "node", DSH_BIN, "web", "--host", "127.0.0.1", "--port", port_s, (char *)NULL);
  _exit(127);
}

static void stop_dsh(void) {
  int pid = read_pid();
  if (pid > 0) {
    if (kill(pid, SIGTERM) == 0) {
      for (int i = 0; i < 30 && kill(pid, 0) == 0; i++) usleep(200000);
      if (kill(pid, 0) == 0) kill(pid, SIGKILL);
    }
  }
  unlink(DSH_JSON);
  unlink(PID_FILE);
}

/** 重读 dsh.json(启动/停止后端口自动匹配,全链路单一事实源) */
static void refresh_port(void) { dsh_port = read_state_port(); }

// ---------- 引导页(任意路径在 dsh 未运行时都会得到它) ----------
static const char TPL[] =
  "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
  "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
  "<link rel=\"manifest\" href=\"/manifest.webmanifest\">"
  "<meta name=\"theme-color\" content=\"#0B0E14\"><title>DeepSeek Harness</title><style>"
  ":root{color-scheme:dark}*{margin:0;padding:0;box-sizing:border-box}html,body{height:100%}"
  "body{background:#0B0E14;color:#E8EAED;font:14px/1.6 -apple-system,BlinkMacSystemFont,\"PingFang SC\",sans-serif;"
  "display:flex;align-items:center;justify-content:center}"
  ".card{text-align:center;max-width:440px;padding:0 24px}"
  ".ring{width:56px;height:56px;margin:0 auto 28px;position:relative}"
  ".ring::before{content:\"\";position:absolute;inset:0;border-radius:50%;border:3px solid rgba(77,107,254,.16)}"
  ".ring::after{content:\"\";position:absolute;inset:0;border-radius:50%;border:3px solid transparent;border-top-color:#4D6BFE;animation:spin 1s linear infinite}"
  "@keyframes spin{to{transform:rotate(360deg)}}"
  ".ring.done::before{display:none}.ring.done::after{display:block;border:0;content:\"\u2713\";color:#4D6BFE;font-size:26px;line-height:56px;animation:none}"
  "h1{font-size:20px;font-weight:600;margin-bottom:10px}#status{color:#9AA3B2;min-height:24px}"
  "#err{display:none;margin-top:18px;color:#F28B82;font-size:13px;text-align:left;background:rgba(242,139,130,.08);border:1px solid rgba(242,139,130,.25);border-radius:10px;padding:10px 14px;word-break:break-all}"
  ".btn{display:none;margin:18px auto 0;background:#4D6BFE;color:#fff;border:0;border-radius:10px;padding:10px 28px;font-size:14px;cursor:pointer}"
  "#log{margin-top:22px;font-size:11px;color:#4A5468}"
  "</style></head><body><div class=\"card\"><div class=\"ring\" id=\"ring\"></div>"
  "<h1>DeepSeek Harness</h1><div id=\"status\">正在连接…</div>"
  "<div id=\"err\"></div><button class=\"btn\" id=\"retry\">重试</button>"
  "<div id=\"log\">日志目录: __LOG_DIR__</div></div><script>"
  "var fired=false,t0=Date.now();"
  "function $(id){return document.getElementById(id)}"
  "function tick(){fetch('/health').then(function(r){return r.json()}).then(function(h){"
  "if(h.dsh){$('ring').className='ring done';$('status').textContent='已就绪,正在进入…';setTimeout(function(){location.reload()},400);return}"
  "if(!fired){fired=true;$('status').textContent='正在唤醒…';fetch('/wake',{method:'POST'})}"
  "var s=Math.floor((Date.now()-t0)/1000);"
  "$('status').textContent='正在启动 DeepSeek Harness…'+(s>=3?'(已等待 '+s+' 秒)':'');"
  "if(s>=600){$('err').style.display='block';$('err').textContent='启动超时(超过 10 分钟)。日志: '+document.getElementById('log').textContent;$('retry').style.display='block'}"
  "}).catch(function(){}).then(function(){setTimeout(tick,500)})}"
  "document.addEventListener('DOMContentLoaded',function(){"
  "document.getElementById('retry').onclick=function(){$('err').style.display='none';this.style.display='none';fired=false;t0=Date.now();tick()};tick()})"
  "</script></body></html>";

static void build_boot(void) {
  const char *p = TPL;
  char *o = BOOT_PAGE;
  const size_t cap = sizeof BOOT_PAGE - 1;
  while (*p && (size_t)(o - BOOT_PAGE) < cap) {
    const char *hit = strstr(p, "__");
    if (!hit) { size_t l = strlen(p); if (l > cap - (size_t)(o - BOOT_PAGE)) l = cap - (size_t)(o - BOOT_PAGE); memcpy(o, p, l); o += l; break; }
    size_t pre = (size_t)(hit - p);
    if (pre > cap - (size_t)(o - BOOT_PAGE)) pre = cap - (size_t)(o - BOOT_PAGE);
    memcpy(o, p, pre); o += pre;
    if (strncmp(hit, "__LOG_DIR__", 11) == 0) { memcpy(o, LOG_DIR, strlen(LOG_DIR)); o += strlen(LOG_DIR); p = hit + 11; }
    else { *o++ = '_'; p = hit + 1; }
  }
  *o = 0;
}

// ---------- HTTP ----------
static void respond(int c, int code, const char *ct, const char *body) {
  char hdr[256];
  int n = snprintf(hdr, sizeof hdr,
    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
    code, code == 200 ? "OK" : "Not Found", ct, strlen(body));
  write(c, hdr, n);
  write(c, body, strlen(body));
}

static void respond_health(int c) {
  char body[128];
  int up = dsh_up();
  snprintf(body, sizeof body, "{\"dsh\":%s,\"port\":%d,\"pid\":%d}",
    up ? "true" : "false", dsh_port, up ? read_pid() : 0);
  respond(c, 200, "application/json", body);
}

static const char MANIFEST[] =
  "{\"name\":\"DeepSeek Harness\",\"short_name\":\"DSH\",\"start_url\":\"/\",\"display\":\"fullscreen\",\"background_color\":\"#0B0E14\",\"theme_color\":\"#0B0E14\"}";

// ---------- 透传 ----------
static void write_all(int fd, const char *b, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, b, n);
    if (w < 0) { if (errno == EINTR || errno == EAGAIN) continue; return; }
    b += w; n -= (size_t)w;
  }
}

static void relay(int c, int u) {
  char cb[65536], ub[65536];
  int c_eof = 0, u_eof = 0;
  while (!(c_eof && u_eof)) {
    struct pollfd pf[2];
    pf[0].fd = c; pf[0].events = POLLIN; pf[0].revents = 0;
    pf[1].fd = u; pf[1].events = POLLIN; pf[1].revents = 0;
    if (poll(pf, 2, 300000) <= 0) continue;
    if (!c_eof && (pf[0].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(c, cb, sizeof cb);
      if (n > 0) write_all(u, cb, (size_t)n);
      else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { c_eof = 1; shutdown(u, SHUT_WR); }
    }
    if (!u_eof && (pf[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(u, ub, sizeof ub);
      if (n > 0) write_all(c, ub, (size_t)n);
      else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { u_eof = 1; shutdown(c, SHUT_WR); }
    }
  }
  close(c);
  close(u);
}

static int connect_upstream(void) {
  for (int i = 0; i < 10; i++) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(dsh_port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
    close(s);
    usleep(100000);
  }
  return -1;
}

// ---------- 单连接处理(fork 出的子进程) ----------
static void handle_conn(int c) {
  struct timeval tv = { 2, 0 };
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  char buf[8192];
  int blen = (int)recv(c, buf, sizeof buf - 1, 0);
  if (blen <= 0) return;
  buf[blen] = 0;

  char method[8] = "", path[1024] = "";
  char *sp1 = strchr(buf, ' ');
  char *sp2 = sp1 ? strchr(sp1 + 1, ' ') : NULL;
  if (sp1 && sp2) {
    size_t ml = (size_t)(sp1 - buf); if (ml >= sizeof method) ml = sizeof method - 1;
    memcpy(method, buf, ml); method[ml] = 0;
    size_t pl = (size_t)(sp2 - (sp1 + 1)); if (pl >= sizeof path) pl = sizeof path - 1;
    memcpy(path, sp1 + 1, pl); path[pl] = 0;
    char *q = strchr(path, '?'); if (q) *q = 0;
  }

  // 每次请求都重读 dsh.json:/wake 拉起 dsh 后端口是守护挑的,停止后文件被删,自动跟随
  refresh_port();
  int up = dsh_up();
  if (!up) {
    if (strcmp(path, "/health") == 0) respond_health(c);
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/wake") == 0) {
      if (NODE_BIN[0] && DSH_BIN[0]) { spawn_dsh(); respond(c, 200, "application/json", "{\"started\":true}"); }
      else respond(c, 500, "application/json", "{\"error\":\"runtime not installed\"}");
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/stop") == 0) {
      respond(c, 200, "application/json", "{\"stopped\":true}");
    } else if (strcmp(path, "/manifest.webmanifest") == 0) respond(c, 200, "application/manifest+json", MANIFEST);
    else respond(c, 200, "text/html; charset=utf-8", BOOT_PAGE);
    return;
  }

  // dsh 就绪:控制路径仍由守护处理,其余双向透传
  if (strcmp(path, "/health") == 0) respond_health(c);
  else if (strcmp(method, "POST") == 0 && strcmp(path, "/wake") == 0) respond(c, 200, "application/json", "{\"dsh\":true}");
  else if (strcmp(method, "POST") == 0 && strcmp(path, "/stop") == 0) {
    stop_dsh();
    respond(c, 200, "application/json", "{\"stopped\":true}");
  } else {
    int u = connect_upstream();
    if (u < 0) { respond(c, 502, "text/plain", "upstream unavailable"); return; }
    write_all(u, buf, (size_t)blen);
    relay(c, u);
  }
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  build_paths();
  build_boot();
  read_run();
  dsh_port = read_state_port();
  if (dsh_port > 0 && !dsh_up()) dsh_port = 0;

  int ls = socket(AF_INET, SOCK_STREAM, 0);
  if (ls < 0) { perror("socket"); return 1; }
  int one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(PORT);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return 1; }
  if (listen(ls, 32) < 0) { perror("listen"); return 1; }
  fprintf(stderr, "dsh-daemon 就绪: http://127.0.0.1:%d/ (PWA 端口;dsh 内部端口自动分配)\n", PORT);

  int active = 0;
  time_t last_exit = time(NULL);
  for (;;) {
    refresh_port();
    int reaped;
    while ((reaped = waitpid(-1, NULL, WNOHANG)) > 0) {
      if (is_spawn(reaped)) continue; // dsh 本体退出不是连接
      active--;
      if (active < 0) active = 0;
      last_exit = time(NULL);
    }
    // PWA 已关闭(无任何连接)→ 空闲自动停止 dsh
    if (dsh_port > 0 && dsh_up() && active == 0 && time(NULL) - last_exit > IDLE_STOP) {
      fprintf(stderr, "daemon: 空闲 %ds 无连接,停止 dsh\n", IDLE_STOP);
      stop_dsh();
      dsh_port = 0;
    }
    struct pollfd p;
    p.fd = ls; p.events = POLLIN; p.revents = 0;
    if (poll(&p, 1, 1000) > 0 && (p.revents & POLLIN)) {
      int c = accept(ls, NULL, NULL);
      if (c >= 0) {
        pid_t pid = fork();
        if (pid == 0) {
          close(ls);
          handle_conn(c);
          close(c);
          _exit(0);
        }
        close(c);
        active++;
      }
    }
  }
  close(ls);
  return 0;
}
