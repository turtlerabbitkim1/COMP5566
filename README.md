# COMP5566 智能合约克隆检测项目 (Smart Contract Code Clone Detection)

本项目旨在通过挖掘 Etherscan 上的活跃智能合约，并利用 TF-IDF 等算法对合约代码进行克隆检测与分析。这是 COMP5566 区块链安全课程的一个实践项目。

## 🛠️ 环境配置

在运行项目之前，请确保已安装 Python 3 以及以下必要的依赖库：

```bash
pip install pandas matplotlib networkx scikit-learn requests beautifulsoup4
```
或者 
```bash
pip install -r requirements.txt
```

### 依赖项说明：
- **requests & beautifulsoup4**: 用于从 Etherscan 获取合约地址和源码。
- **pandas**: 用于处理克隆报告数据（CSV 格式）。
- **scikit-learn**: 提供 TF-IDF 向量化工具和余弦相似度计算。
- **networkx**: 用于分析克隆“家族”（连通图聚类）。
- **matplotlib**: 用于绘制相似度分布统计图。

## 🚀 项目启动流程

请按照以下顺序在终端运行脚本：

### 第一步：获取合约地址
运行以下脚本从 Etherscan 获取最新的活跃合约地址：
```bash
python3 get_50_addresses.py
```
*输出：生成 `addresses.txt` 文件。*

### 第二步：下载合约源码
根据获取到的地址下载已开源的合约源码：
```bash
python3 download_400.py
```
*输出：合约源码将保存至 `contracts/` 目录。*

### 第三步：进行克隆检测
使用极速 TF-IDF 算法对比所有已下载合约的相似度：
```bash
python3 super_fast_detect.py
```
*输出：生成 `fast_clone_report.csv` 详细报告。*

### 第四步：分析克隆家族
分析哪些合约属于同一个“家族”（高度相似的群体）：
```bash
python3 cluster_stats.py
```
*输出：终端打印克隆统计报告和家族列表。*

### 第五步：生成统计图表
将相似度分布可视化：
```bash
python3 draw_stats.py
```
*输出：生成 `clone_distribution_bar.png` 统计图。*

## 📂 文件结构说明

- `get_50_addresses.py`: 地址挖掘脚本。
- `download_400.py`: 源码下载脚本。
- `super_fast_detect.py`: 核心检测脚本（推荐使用）。
- `analyze_clones.py`: 深度比对检测脚本（较慢）。
- `cluster_stats.py`: 家族聚类分析工具。
- `draw_stats.py`: 可视化绘图工具。
- `contracts/`: 存放下载的 `.sol` 合约文件。
- `fast_clone_report.csv`: 记录所有相似对的相似度。
- `clone_distribution_bar.png`: 克隆分布直方图。

## 📝 注意事项
- 脚本中使用了免费版的 Etherscan API Key，如果下载速度受限，请在脚本中更换为您自己的 API Key。
- 相似度阈值默认设定为 60%，您可以在 `super_fast_detect.py` 中进行调整。
