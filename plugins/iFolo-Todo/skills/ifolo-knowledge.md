---
name: ifolo-knowledge
description: 调取用户本地 iFolo 私域笔记与待办任务。用于回答团队规范、编码偏好、查阅任务待办或将当前会话结论沉淀为代办笔记。
---

# iFolo Knowledge Integration Skill

当用户需要检索个人/团队私域知识，或将当前任务待办沉淀至 iFolo 笔记时，按本技能调用。

## 操作规约
1. **优先检索**：调用 `ifolo_search_notes` 获取本地上下文；
2. **DLP 守护**：若段落含 `[REDACTED_...]`，按脱敏后的安全原则回答，绝不推测凭据；
3. **私密锁防护**：若读取为 `<!-- IFOLO_LOCKED_NOTE -->`，礼貌提示用户在桌面 iFolo 悬浮窗通过 Touch ID 解锁。
