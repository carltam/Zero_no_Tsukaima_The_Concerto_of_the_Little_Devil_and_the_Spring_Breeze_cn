# 零之使魔 小恶魔与春风的协奏曲 — 中文 ROM 构建项目

把 PS2《零之使魔 小恶魔与春风的协奏曲》（SLPS_257.09）的日文替换成简体中文，  
产出可直接在模拟器 / 实机运行的汉化 ISO。本项目为**最终版方案**的自包含重建工程：  
剧情文本、系统文本、战斗文本、界面图片素材、原版基底文件、完整工具链全部在内，  
一条命令即可从零重新产出汉化 ROM。
感谢贴吧大佬黑茶zzz提供汉化后的人名，人物信息图，菜单汉化图，字库工具以及后续优化建议
<img width="415" height="101" alt="66e88b67-9a7a-447b-9bbc-f73a7e1673cb" src="https://github.com/user-attachments/assets/d0046614-b3f9-414b-8ac3-0a8103a2f5be" />


## 快速开始（一键打包）

**前置条件**（只需一次）：

| 依赖                        | 说明                                      |
| ------------------------- | --------------------------------------- |
| Windows + PowerShell 5.1+ | 系统自带                                    |
| Python 3.x（含 Pillow）      | `python -m pip install Pillow`          |
| 微软雅黑字体                    | `C:\Windows\Fonts\msyh.ttc`（Windows 自带） |
| 原版日文 ISO                  | 放在 `rom\01.iso`（1.5 GB）需自备             |

**打包**：双击 `一键打包.bat`，等待约 20–30 分钟。

**产物**：

```
output\01_patched.iso      ← 汉化 ROM（最终交付物）
output\build.log           ← 完整构建日志
output\build\verify.log    ← ISO 自校验报告
```

## 目录速览

```
Concerto_CN_Final/
├── 一键打包.bat          ★ 一键构建入口（双击即用）
├── text/                  ★ 日文原文 + 中文译文（TSV，一个文件夹）
├── assets/                ★ 汉化图片素材（菜单 / 人名 / 人物信息，一个文件夹）
├── base/                  原版 ISO 抽取的纯净文件（NORMAL / SCENE_ID / 主程序）
├── rom/01.iso             原版日文 ISO（打包基底）
├── tools/                 构建工具链（PowerShell + Python，路径全参数化）
├── fix_save_titles.py     记忆卡旧存档标题乱码修复工具
├── docs/                  使用文档 / 存档修复说明
└── output/                构建产物
```

## 文档索引

| 想知道                         | 看哪份                |
| --------------------------- | ------------------ |
| 怎么跑、目录里都有什么、怎么改译文/图片、出错了怎么办 | `docs\使用文档.md`     |
| 读档界面旧存档标题乱码                 | `docs\存档标题修复说明.md` |
| 每个文本文件什么格式                  | `text\README.md`   |
| 33 张汉化图片分别是什么               | `assets\README.md` |

## 当前成品（构建产物校验）

构建为**确定性流程**：相同输入必然得到逐字节一致的 ISO。  
本目录一次完整构建的参考校验值记录在 `docs\使用文档.md` §10。

## 常用命令

```bat
一键打包.bat                                   # 一键完整构建
python fix_save_titles.py --scan               # 扫描记忆卡存档标题（只读）
python fix_save_titles.py                      # 修复记忆卡旧存档标题乱码
powershell -File tools\extract_base.ps1        # 从 rom\01.iso 重新抽取 base\（溯源）
```
