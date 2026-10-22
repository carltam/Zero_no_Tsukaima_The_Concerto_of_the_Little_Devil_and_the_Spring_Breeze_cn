#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修复 PS2 记忆卡中《零之使魔 小恶魔与春风的协奏曲》存档标题乱码。

背景与根因
----------
读档界面的章节标题在存档里是「裸字节」：游戏存盘时把脚本里设置的标题码
原样拷贝进记忆卡（主程序 0x1184d8 是纯 strncpy，无码制转换），读档时再用
同一套 NORMAL.BIN 字体码表渲染。开发过程早期构建写入的旧存档使用的是当时的
码位分配，与最终版码表已有出入（例如旧码 8CA8=「託」，最终版 8CA8=「肩」），
于是读档界面显示乱码汉字。最终版 ROM 对新存档写入的标题本来就是正确的；
本工具只用于修复已经存在的旧存档，无需重新通关。

用法
----
    # 扫描：列出记忆卡中所有存档标题及解码情况（只读，不写任何数据）
    python fix_save_titles.py --scan

    # 修复：按内置修复表重写标题（写前自动备份，写后自动校验，可重复运行）
    python fix_save_titles.py

    # 指定记忆卡 / 构建产物目录
    python fix_save_titles.py --mcd D:/emu/memcards/Mcd001.ps2 --build-dir output/build

    # 追加自定义修复（偏移用 --scan 获取，格式: 十六进制偏移:正确标题）
    python fix_save_titles.py --fix 0x2211494:黑发来客 --fix 0x22262b4:託裏斯塔尼亚的危机

说明：--fix 可多次使用；与内置修复表合并（同偏移后者覆盖前者）。
"""
import argparse
import os
import re
import shutil
import sys
import time

SAVE_DIR = b"BISLPS-25708"          # 协奏曲在记忆卡上的存档目录名
DEFAULT_MCD = "F:/PS2/ps2emu/memcards/Mcd001.ps2"
TITLE_MAX = 60                       # 标题缓冲区扫描上限（实际缓冲 100 字节）

# 已验证的修复表（偏移量为标题缓冲区起始；适用于随项目附带的那张记忆卡）
DEFAULT_FIXES = [
    (0x2211494, "黑发来客"),            # save01（原为「涼懐来給」，进度标记 96423 -> 场景 00068）
    (0x2224e14, "女人的战斗"),          # save02（原为「女人的検」，00137）
    (0x22262b4, "託裏斯塔尼亚的危机"),  # save04（原为「肩補…危撮」，00219）
    (0x2227b74, "真正的心意"),          # save03（原为「真正的心隙」，00269）
]


def load_codemap(build_dir):
    """加载最终版合并码表：encoding_map.txt（自定义码）+ native_reuse.txt（复用原版 SJIS 码）。"""
    char2code = {}
    for name in ("encoding_map.txt", "native_reuse.txt"):
        path = os.path.join(build_dir, name)
        if not os.path.exists(path):
            sys.exit("[错误] 找不到码表 %s\n       请先运行一键打包生成构建产物，或用 --build-dir 指定目录。" % path)
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line:
                continue
            ch, code = line.split("\t")
            char2code[ch] = int(code, 16)
    if not char2code:
        sys.exit("[错误] 码表为空：%s" % build_dir)
    return char2code


def decode_codes(buf, char2code):
    """把双字节码流解码为文本；未知码以 <XXXX> 标注。返回 (文本, 未知码个数)。"""
    code2char = {v: k for k, v in char2code.items()}
    out, unknown = [], 0
    for i in range(0, len(buf) - 1, 2):
        c = (buf[i] << 8) | buf[i + 1]
        if c == 0:
            break
        ch = code2char.get(c)
        if ch is None:
            unknown += 1
            out.append("<%04X>" % c)
        else:
            out.append(ch)
    return "".join(out), unknown


def encode_text(text, char2code):
    """把中文文本编码为游戏双字节码；返回 (bytes, 缺失字列表)。"""
    out, missing = bytearray(), []
    for ch in text:
        code = char2code.get(ch)
        if code is None:
            missing.append(ch)
            continue
        out += code.to_bytes(2, "big")
    return bytes(out), missing


def scan_titles(data, char2code):
    """在记忆卡里定位 BISLPS-25708 存档目录之后的全部标题缓冲区。

    判定：一段以 00 00 结尾、长度 4..TITLE_MAX 的双字节码流，
    按最终码表解码后有 >=2 个已知汉字（乱码旧档通常也含若干已知字）。
    """
    code2char = {v: k for k, v in char2code.items()}
    found = []
    for m in re.finditer(re.escape(SAVE_DIR), data):
        base = m.start()
        window_end = min(len(data), base + 0x8000)
        off = base
        while off + 1 < window_end:
            if data[off] == 0 and data[off + 1] == 0:
                off += 2
                continue
            # 尝试从 off 开始取一段码流
            j, known = off, 0
            while j + 1 < window_end and data[j:j + 2] != b"\x00\x00" and j - off < TITLE_MAX:
                c = (data[j] << 8) | data[j + 1]
                if c in code2char:
                    known += 1
                j += 2
            if j - off >= 4 and known >= 2:
                raw = bytes(data[off:j])
                text, unknown = decode_codes(raw, char2code)
                if not found or off - found[-1][0] >= 4:
                    found.append((off, raw, text, unknown))
                off = j
            else:
                off += 2
    # 去掉相互重叠的候选（保留先出现的）
    dedup = []
    for off, raw, text, unknown in found:
        if dedup and off < dedup[-1][0] + len(dedup[-1][1]):
            continue
        dedup.append((off, raw, text, unknown))
    return dedup


def reference_titles(work_dir):
    """从构建中间产物里提取 29 个章节标题（title("...") 调用），供人工核对。"""
    scene_dir = os.path.join(work_dir, "scene_pristine")
    if not os.path.isdir(scene_dir):
        return []
    pat = re.compile(rb'title\("(.*?)"\);', re.DOTALL)
    titles = []
    for fn in sorted(os.listdir(scene_dir)):
        if not fn.endswith(".nut"):
            continue
        data = open(os.path.join(scene_dir, fn), "rb").read()
        for m in pat.finditer(data):
            raw = m.group(1)
            if len(raw) >= 4 and len(raw) % 2 == 0:
                titles.append((fn[:-4], raw))
    return titles


def cmd_scan(args, char2code):
    data = open(args.mcd, "rb").read()
    hits = scan_titles(data, char2code)
    if not hits:
        print("未在 %s 中找到 %s 存档标题（记忆卡里没有该游戏的存档？）" % (args.mcd, SAVE_DIR.decode()))
        return 0
    print("记忆卡: %s" % args.mcd)
    print("存档目录: %s" % SAVE_DIR.decode())
    print("找到 %d 个标题缓冲区：\n" % len(hits))
    for off, raw, text, unknown in hits:
        flag = "乱码(旧档)" if unknown else "正常"
        print("  @0x%X  %-10s %s" % (off, flag, text))
        print("      raw: %s" % raw.hex())
    refs = reference_titles(os.path.join(os.path.dirname(os.path.abspath(__file__)), "_build_work"))
    if refs:
        print("\n参考：当前构建的 %d 个章节标题（来自 _build_work/scene_pristine）：" % len(refs))
        for sid, raw in refs:
            print("  %s.nut: %s" % (sid, raw.decode("utf-16-be", errors="replace")))
    else:
        print("\n（未找到 _build_work/scene_pristine，跳过章节标题参考列表；")
        print("  跑过一次一键打包后即可附带此列表。）")
    print("\n修复方法: python fix_save_titles.py --fix <偏移>:<正确标题> ...")
    return 0


def cmd_fix(args, char2code):
    fixes = dict(DEFAULT_FIXES)
    for item in args.fix or []:
        if ":" not in item:
            sys.exit("[错误] --fix 格式应为 十六进制偏移:标题，例如 0x2211494:黑发来客")
        off_s, title = item.split(":", 1)
        fixes[int(off_s, 16)] = title

    if not os.path.exists(args.mcd):
        sys.exit("[错误] 记忆卡不存在: %s" % args.mcd)
    data = bytearray(open(args.mcd, "rb").read())

    # 预校验：所有标题必须能用最终码表完整编码
    for off, title in sorted(fixes.items()):
        _, missing = encode_text(title, char2code)
        if missing:
            sys.exit("[错误] 标题「%s」含码表缺失字 %s，无法编码（先跑一键打包再修复）" % (title, missing))

    changed = 0
    for off, title in sorted(fixes.items()):
        new, _ = encode_text(title, char2code)
        old = bytes(data[off:off + TITLE_MAX])
        old_len = 0
        while old_len + 1 < len(old) and old[old_len:old_len + 2] != b"\x00\x00":
            old_len += 2
        old_title = old[:old_len]
        if old_title == new:
            print("@0x%X: 已是正确标题「%s」，跳过" % (off, title))
            continue
        # 备份（每次运行一个带时间戳的副本，只备份一次）
        if changed == 0 and not args.no_backup:
            bak = "%s.bak_titlefix_%s" % (args.mcd, time.strftime("%Y%m%d_%H%M%S"))
            shutil.copy2(args.mcd, bak)
            print("已备份记忆卡 -> %s" % bak)
        # 写入：先清空旧标题区（含结尾 00 00 前的残余），再写新码 + 结束符
        span = max(len(new), old_len)
        data[off:off + span] = b"\x00" * span
        data[off:off + len(new)] = new
        print("@0x%X: 「%s」" % (off, title))
        print("   旧(%dB): %s" % (old_len, old_title.hex()))
        print("   新(%dB): %s" % (len(new), new.hex()))
        changed += 1

    if changed == 0:
        print("无需修复（所有标题均正确）。")
        return 0

    open(args.mcd, "wb").write(data)

    # 写后校验：重新读盘解码，必须与目标标题一致
    verify = open(args.mcd, "rb").read()
    bad = 0
    for off, title in sorted(fixes.items()):
        raw = verify[off:off + TITLE_MAX]
        n = 0
        while n + 1 < len(raw) and raw[n:n + 2] != b"\x00\x00":
            n += 2
        text, unknown = decode_codes(raw[:n], char2code)
        if text != title or unknown:
            print("[校验失败] @0x%X 读出「%s」!= 「%s」" % (off, text, title))
            bad += 1
    if bad:
        sys.exit("[错误] %d 个标题校验失败，记忆卡可能损坏，请用备份还原。" % bad)
    print("\n完成：修复 %d 个标题，写后校验全部通过。" % changed)
    print("生效方法：在 PCSX2 中退出到 PS2 浏览器或重启一次模拟器，再进读档界面查看。")
    return 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(
        description="修复 PS2 记忆卡中零之使魔·协奏曲的存档标题乱码",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n  python fix_save_titles.py --scan\n  python fix_save_titles.py\n  python fix_save_titles.py --fix 0x2211494:黑发来客")
    ap.add_argument("--mcd", default=DEFAULT_MCD, help="记忆卡 .ps2 文件路径（默认 %(default)s）")
    ap.add_argument("--build-dir", default=os.path.join(here, "output", "build"),
                    help="构建产物目录（含 encoding_map.txt / native_reuse.txt，默认 %(default)s）")
    ap.add_argument("--scan", action="store_true", help="只扫描报告，不写任何数据")
    ap.add_argument("--fix", action="append", help="追加修复项，格式 十六进制偏移:标题，可多次")
    ap.add_argument("--no-backup", action="store_true", help="跳过写前自动备份（不推荐）")
    args = ap.parse_args()

    char2code = load_codemap(args.build_dir)
    if args.scan:
        return cmd_scan(args, char2code)
    return cmd_fix(args, char2code)


if __name__ == "__main__":
    sys.exit(main())
