// Minimal SMTP over implicit TLS (port 465), enough to send one plain-text message.
// Used for the contact form; configured with MAIL_HOST, MAIL_USER, MAIL_PASS, MAIL_TO.
import { connect } from "node:tls";

export const mailConfigured = () => !!(process.env.MAIL_USER && process.env.MAIL_PASS && process.env.MAIL_TO);

const header = (s: string) => s.replace(/[\r\n]+/g, " ").trim();
const encodeWord = (s: string) => /^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${Buffer.from(s).toString("base64")}?=`;

export async function sendMail(subject: string, text: string, replyTo?: string): Promise<void> {
  const host = process.env.MAIL_HOST ?? "smtp.gmail.com";
  const user = process.env.MAIL_USER!, pass = process.env.MAIL_PASS!, to = process.env.MAIL_TO!;
  const sock = connect({ host, port: 465, servername: host });
  let buf = "";
  const waiters: ((line: string) => void)[] = [];
  sock.setEncoding("utf8");
  sock.on("data", (d: string) => {
    buf += d;
    // a reply is complete when a line has "<code> " (not "<code>-")
    let m;
    while ((m = buf.match(/^(\d{3}) .*\r\n/m))) {
      const end = buf.indexOf(m[0]) + m[0].length;
      const reply = buf.slice(0, end);
      buf = buf.slice(end);
      waiters.shift()?.(reply);
    }
  });
  const reply = () => new Promise<string>((res, rej) => {
    waiters.push(res);
    sock.once("error", rej);
    setTimeout(() => rej(new Error("SMTP timeout")), 20000);
  });
  const expect = async (code: string, send?: string) => {
    const r = reply();
    if (send !== undefined) sock.write(send + "\r\n");
    const line = await r;
    if (!line.startsWith(code)) throw new Error(`SMTP: ${line.trim()}`);
  };

  try {
    await expect("220");
    await expect("250", "EHLO roomprint");
    await expect("235", "AUTH PLAIN " + Buffer.from(`\0${user}\0${pass}`).toString("base64"));
    await expect("250", `MAIL FROM:<${user}>`);
    await expect("250", `RCPT TO:<${to}>`);
    await expect("354", "DATA");
    const body = text.replace(/\r?\n/g, "\r\n").replace(/^\./gm, "..");
    const msg = [
      `From: Roomprint <${user}>`,
      `To: <${to}>`,
      ...(replyTo ? [`Reply-To: <${header(replyTo)}>`] : []),
      `Subject: ${encodeWord(header(subject))}`,
      `Date: ${new Date().toUTCString()}`,
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: 8bit",
      "",
      body,
      ".",
    ].join("\r\n");
    await expect("250", msg);
    sock.write("QUIT\r\n");
  } finally {
    sock.end();
  }
}
