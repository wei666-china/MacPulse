# 安全政策 / Security Policy

## 报告漏洞

发现安全问题请**不要**开公开 issue,改用 GitHub 的
[私密漏洞报告](../../security/advisories/new)(Security → Report a vulnerability)。
我们会尽快确认与修复,并在修复发布后公开致谢。

## 安全设计要点

- **对硬件只读**:SMC/IOReport 只有读取路径,代码中不存在任何写入硬件的调用
  (无风扇控制、无充电控制、无电压写入)
- **无提权**:不请求 root、无特权 Helper、无系统扩展;全部数据来自
  无需权限的公开系统接口
- **网络面极小**:唯一的出网行为是用户明确同意后的网络测速
  (`speed.cloudflare.com` 传输计时用的填充字节 + `captive.apple.com`
  连通性检测,一个 HEAD 级请求)。不同意则零请求
- **无遥测**:不收集、不上传任何设备信息或使用数据;历史仅存本机
- **解析面受控**:App 只解析本机系统工具输出与自家采集器的 NDJSON,
  不解析任何远程输入
