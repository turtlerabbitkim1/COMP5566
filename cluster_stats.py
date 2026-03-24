import pandas as pd
import networkx as nx
import os

def analyze_clusters():
    csv_file = 'fast_clone_report.csv'
    if not os.path.exists(csv_file):
        print("找不到文件")
        return

    df = pd.read_csv(csv_file)
    
    # 设定一个严格的克隆标准，比如相似度 > 95% 才算一家人
    THRESHOLD = 95.0
    df_clones = df[df['Similarity'] >= THRESHOLD]

    # 建图
    G = nx.Graph()
    for _, row in df_clones.iterrows():
        G.add_edge(row['Contract A'], row['Contract B'])

    # 寻找“家族”（连通子图）
    # 如果 A 和 B 像，B 和 C 像，那么 A,B,C 就是一个家族
    clusters = list(nx.connected_components(G))
    
    # 按家族里的人数从多到少排序
    clusters.sort(key=len, reverse=True)
    
    # 统计总共有多少个独立合约参与了克隆
    total_cloned_contracts = sum(len(c) for c in clusters)
    
    # 动态统计总合约数
    path = 'contracts'
    TOTAL_FILES = len([f for f in os.listdir(path) if f.endswith('.sol')])
    clone_ratio = (total_cloned_contracts / TOTAL_FILES) * 100 if TOTAL_FILES > 0 else 0

    print("📊 --- 真实的克隆统计报告 ---")
    print(f"样本总数: {TOTAL_FILES} 个智能合约")
    print(f"参与克隆的合约总数: {total_cloned_contracts} 个")
    print(f"生态总体克隆率: {clone_ratio:.2f}%\n")
    
    print(f"这些克隆合约共划分为 {len(clusters)} 个克隆家族：")
    for i, cluster in enumerate(clusters):
        print(f"🏠 家族 {i+1} (共包含 {len(cluster)} 个合约):")
        # 随便挑三个名字打印出来作为代表
        examples = list(cluster)[:3]
        print(f"   代表成员: {', '.join([e.split('_')[0] for e in examples])}...")

if __name__ == "__main__":
    analyze_clusters()