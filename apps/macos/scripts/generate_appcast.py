#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sparkle 2 Appcast Generator for iFolo Note

自动为 Apple Silicon (arm64) 与 Intel (x86_64) 双架构 DMG 生成签名，
并维护符合 Sparkle 2 规范的 appcast.xml 增量更新 Feed。

支持特性：
1. 环境变量 / Keychain / 参数多源读取 EdDSA 签名密钥 (SPARKLE_ED_KEY)
2. 自动检测并区分「强制关键更新」(Critical Update) 与「非强制常规更新」
3. 规范化 XML 输出，包含 sparkle:os="macos" 与 sparkle:cpu 架构分流
4. 增量维护历史版本条目，防止覆盖已有发行记录
"""

import os
import sys
import argparse
import subprocess
import email.utils
import datetime
import xml.etree.ElementTree as ET
from xml.dom import minidom

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

def get_ed_signature(sign_tool: str, file_path: str, ed_key: str = None, account: str = "ifolo-eddsa") -> str:
    """调用 Sparkle sign_update 工具计算并返回 EdDSA 签名"""
    if not os.path.exists(sign_tool):
        raise FileNotFoundError(f"Sparkle sign_update tool not found at: {sign_tool}")

    cmd = [sign_tool, "-p"]
    input_data = None

    if ed_key:
        cmd.extend(["--ed-key-file", "-"])
        input_data = ed_key.strip().encode("utf-8")
    else:
        cmd.extend(["--account", account])

    cmd.append(file_path)

    proc = subprocess.run(cmd, input=input_data, capture_output=True, check=True)
    sig = proc.stdout.decode("utf-8").strip()
    if not sig:
        raise RuntimeError(f"Failed to get EdDSA signature: {proc.stderr.decode('utf-8')}")
    return sig

def format_rfc2822(dt: datetime.datetime = None) -> str:
    if dt is None:
        dt = datetime.datetime.now(datetime.timezone.utc)
    return email.utils.format_datetime(dt)

def build_appcast(
    dist_dir: str,
    sign_tool: str,
    output_xml: str,
    version: str,
    build_num: str,
    release_tag: str,
    release_notes: str,
    is_critical: bool,
    ed_key: str = None,
    repo_url: str = "https://github.com/XideaDev/iFolo-Note"
):
    arm_dmg = os.path.join(dist_dir, f"iFolo-{version}-arm64.dmg")
    if not os.path.exists(arm_dmg):
        arm_dmg = os.path.join(dist_dir, "iFolo-arm64.dmg")

    x86_dmg = os.path.join(dist_dir, f"iFolo-{version}-x86_64.dmg")
    if not os.path.exists(x86_dmg):
        x86_dmg = os.path.join(dist_dir, "iFolo-x86_64.dmg")

    if not os.path.exists(arm_dmg) and not os.path.exists(x86_dmg):
        raise FileNotFoundError(f"未找到可签名的 DMG 文件。dist_dir={dist_dir}")

    print(f"==> 正在为 iFolo v{version} (Build {build_num}) 生成 Sparkle 签名...")

    enclosures = []

    if os.path.exists(arm_dmg):
        arm_sig = get_ed_signature(sign_tool, arm_dmg, ed_key)
        arm_len = str(os.path.getsize(arm_dmg))
        arm_url = f"{repo_url}/releases/download/{release_tag}/{os.path.basename(arm_dmg)}"
        enclosures.append({
            "url": arm_url,
            "length": arm_len,
            "sig": arm_sig,
            "cpu": "arm64",
            "file": arm_dmg
        })
        print(f"  ✓ Apple Silicon (arm64): {os.path.basename(arm_dmg)} ({arm_len} bytes)")

    if os.path.exists(x86_dmg):
        x86_sig = get_ed_signature(sign_tool, x86_dmg, ed_key)
        x86_len = str(os.path.getsize(x86_dmg))
        x86_url = f"{repo_url}/releases/download/{release_tag}/{os.path.basename(x86_dmg)}"
        enclosures.append({
            "url": x86_url,
            "length": x86_len,
            "sig": x86_sig,
            "cpu": "x86_64",
            "file": x86_dmg
        })
        print(f"  ✓ Intel Mac (x86_64): {os.path.basename(x86_dmg)} ({x86_len} bytes)")

    # 载入已有 appcast.xml 或创建全新骨架
    existing_items = []
    if os.path.exists(output_xml):
        try:
            tree = ET.parse(output_xml)
            root = tree.getroot()
            channel = root.find("channel")
            if channel is not None:
                for item in channel.findall("item"):
                    item_ver = item.find(f"{{{SPARKLE_NS}}}shortVersionString")
                    item_build = item.find(f"{{{SPARKLE_NS}}}version")
                    # 避免同版本重复堆叠
                    if item_ver is not None and item_ver.text == version:
                        if item_build is not None and item_build.text == build_num:
                            continue
                    existing_items.append(item)
        except Exception as e:
            print(f"⚠️ 读取已有 {output_xml} 失败，将重新生成: {e}")

    root = ET.Element("rss", {
        "version": "2.0"
    })
    channel = ET.SubElement(root, "channel")

    ch_title = ET.SubElement(channel, "title")
    ch_title.text = "iFolo Note 自动更新频道"
    ch_link = ET.SubElement(channel, "link")
    ch_link.text = "https://www.ifolo.cn"
    ch_desc = ET.SubElement(channel, "description")
    ch_desc.text = "iFolo Note macOS 最新版本与安全修复发布频道"
    ch_lang = ET.SubElement(channel, "language")
    ch_lang.text = "zh-CN"

    # 插入最新发布 item
    new_item = ET.SubElement(channel, "item")
    it_title = ET.SubElement(new_item, "title")
    it_title.text = f"iFolo Note v{version}"

    it_pub = ET.SubElement(new_item, "pubDate")
    it_pub.text = format_rfc2822()

    it_bld = ET.SubElement(new_item, f"{{{SPARKLE_NS}}}version")
    it_bld.text = str(build_num)

    it_ver = ET.SubElement(new_item, f"{{{SPARKLE_NS}}}shortVersionString")
    it_ver.text = str(version)

    it_min = ET.SubElement(new_item, f"{{{SPARKLE_NS}}}minimumSystemVersion")
    it_min.text = "14.0"

    # 若为关键/强制安全更新，写入 sparkle:criticalUpdate 节点
    if is_critical:
        ET.SubElement(new_item, f"{{{SPARKLE_NS}}}criticalUpdate")
        print("  🚨 已标记为此版本为关键强制更新 (<sparkle:criticalUpdate />)")

    it_desc = ET.SubElement(new_item, "description")
    if release_notes:
        notes_clean = release_notes.replace("\\n", "\n").strip()
        lines = [l.strip() for l in notes_clean.split("\n") if l.strip()]
        if len(lines) > 1:
            header = lines[0]
            items = []
            for l in lines[1:]:
                item_text = l.lstrip("•- \t")
                if "：" in item_text:
                    k, v = item_text.split("：", 1)
                    items.append(f"<li><b>{k}</b>：{v}</li>")
                elif ":" in item_text:
                    k, v = item_text.split(":", 1)
                    items.append(f"<li><b>{k}</b>：{v}</li>")
                else:
                    items.append(f"<li>{item_text}</li>")
            it_desc.text = f"<p><b>{header}</b></p><ul>{''.join(items)}</ul>"
        else:
            it_desc.text = notes_clean
    else:
        it_desc.text = f"iFolo Note v{version} 稳定版更新"
    for enc in enclosures:
        ET.SubElement(new_item, "enclosure", {
            "url": enc["url"],
            "length": enc["length"],
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": enc["sig"],
            f"{{{SPARKLE_NS}}}os": "macos",
            f"{{{SPARKLE_NS}}}cpu": enc["cpu"]
        })

    # 追加已有历史版本
    for old_item in existing_items:
        channel.append(old_item)

    # 规范化美化输出 XML
    xml_str = ET.tostring(root, encoding="utf-8")
    dom = minidom.parseString(xml_str)
    pretty_xml = dom.toprettyxml(indent="    ", encoding="utf-8")

    # 去除多余空行
    clean_lines = [line for line in pretty_xml.decode("utf-8").splitlines() if line.strip()]
    final_xml = "\n".join(clean_lines) + "\n"

    with open(output_xml, "w", encoding="utf-8") as f:
        f.write(final_xml)

    print(f"✓ 成功生成并写入: {output_xml}")

def main():
    parser = argparse.ArgumentParser(description="Generate Sparkle 2 appcast.xml for iFolo Note")
    parser.add_argument("--dist", default="dist", help="DMG 文件目录 (默认 dist)")
    parser.add_argument("--sign-tool", default="apps/macos/scripts/sparkle/sign_update", help="sign_update 工具路径")
    parser.add_argument("--output", default="appcast.xml", help="输出 appcast.xml 路径")
    parser.add_argument("--version", help="版本号 (如 0.1.1，默认自动读取 Info.plist)")
    parser.add_argument("--build", default="1", help="构建号 CFBundleVersion (默认 1)")
    parser.add_argument("--tag", help="Release Tag (如 v0.1.1，默认根据 version 拼接)")
    parser.add_argument("--notes", default="", help="更新说明文本或 markdown 文件路径")
    parser.add_argument("--critical", action="store_true", help="是否为强制关键更新 (Critical Update)")
    parser.add_argument("--key", help="EdDSA 私钥 Base64 (未指定时优先读取 $SPARKLE_ED_KEY，否则访问 Keychain)")

    args = parser.parse_args()

    # 读取 Info.plist 版本号兜底
    version = args.version
    if not version:
        try:
            import plistlib
            with open("apps/macos/Resources/Info.plist", "rb") as f:
                pl = plistlib.load(f)
                version = pl.get("CFBundleShortVersionString", "0.1.1")
                args.build = pl.get("CFBundleVersion", args.build)
        except Exception:
            version = "0.1.1"

    release_tag = args.tag or f"v{version}"

    # 读取更新日志
    notes = args.notes
    if notes and os.path.isfile(notes):
        with open(notes, "r", encoding="utf-8") as f:
            notes = f.read()

    # 读取私钥
    ed_key = args.key or os.environ.get("SPARKLE_ED_KEY")

    build_appcast(
        dist_dir=args.dist,
        sign_tool=args.sign_tool,
        output_xml=args.output,
        version=version,
        build_num=args.build,
        release_tag=release_tag,
        release_notes=notes,
        is_critical=args.critical,
        ed_key=ed_key
    )

if __name__ == "__main__":
    main()
