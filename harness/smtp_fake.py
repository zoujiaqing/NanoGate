#!/usr/bin/env python3
"""明文 SMTP 假服务器：走完整握手（EHLO / AUTH LOGIN / MAIL / RCPT / DATA / QUIT），
把最后一封信解析后写成 JSON 到 DUMP 文件，供 harness 断言鉴权、收发件人、主题与正文。
用法：PORT=2525 DUMP=/tmp/x.json python3 smtp_fake.py
"""
import base64, email, email.policy, json, os, re, socketserver

PORT = int(os.environ.get("PORT", "2525"))
DUMP = os.environ.get("DUMP", "/tmp/smtp-fake.json")


class H(socketserver.StreamRequestHandler):
    def w(self, s):
        self.wfile.write((s + "\r\n").encode()); self.wfile.flush()

    def line(self):
        return self.rfile.readline().decode(errors="replace").rstrip("\r\n")

    def handle(self):
        user = pw = None; mail_from = None; rcpts = []; data = None
        self.w("220 fake.smtp ESMTP")
        while True:
            l = self.line()
            if not l: break
            u = l.upper()
            if u.startswith("EHLO") or u.startswith("HELO"):
                self.w("250-fake.smtp"); self.w("250-AUTH LOGIN PLAIN"); self.w("250 8BITMIME")
            elif u.startswith("AUTH LOGIN"):
                self.w("334 VXNlcm5hbWU6"); user = base64.b64decode(self.line()).decode()
                self.w("334 UGFzc3dvcmQ6"); pw = base64.b64decode(self.line()).decode()
                self.w("235 ok")
            elif u.startswith("AUTH PLAIN"):
                # libcurl 优先用 PLAIN：一行带 token（或先 334 再发）
                tok = l[10:].strip() or (self.w("334 ") or self.line())
                parts = base64.b64decode(tok).decode().split("\x00")
                user, pw = parts[-2], parts[-1]; self.w("235 ok")
            elif u.startswith("MAIL FROM:"):
                mail_from = re.search(r"<([^>]*)>", l).group(1); self.w("250 ok")
            elif u.startswith("RCPT TO:"):
                rcpts.append(re.search(r"<([^>]*)>", l).group(1)); self.w("250 ok")
            elif u == "DATA":
                self.w("354 go")
                buf = []
                while True:
                    x = self.rfile.readline().decode(errors="replace")
                    if x.rstrip("\r\n") == ".": break
                    buf.append(x)
                data = "".join(buf); self.w("250 queued")
                msg = email.message_from_string(data, policy=email.policy.default)
                json.dump({"user": user, "password": pw, "from": mail_from, "rcpts": rcpts,
                           "subject": str(msg["Subject"]), "from_header": str(msg["From"]),
                           "content_type": msg.get_content_type(), "body": msg.get_content(),
                           "has_date": bool(msg["Date"]), "has_message_id": bool(msg["Message-ID"])}, open(DUMP, "w"), ensure_ascii=False)
            elif u == "QUIT":
                self.w("221 bye"); break
            else:
                self.w("250 ok")


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


S(("127.0.0.1", PORT), H).serve_forever()
