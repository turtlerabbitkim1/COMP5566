import os
import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity

def super_fast_detect():
    path = 'contracts'
    files = [f for f in os.listdir(path) if f.endswith('.sol')]
    
    if not os.path.exists(path):
        print(f"❌ 找不到目录: {path}")
        return
    
    print(f"💾 正在读取 {len(files)} 个文件...")
    codes = []
    valid_files = []
    
    for f in files:
        with open(os.path.join(path, f), 'r', encoding='utf-8', errors='ignore') as src:
            content = src.read()
            if len(content) > 300: # 过滤掉太短的无用文件
                codes.append(content)
                valid_files.append(f)
    
    print("🚀 正在使用 TF-IDF 算法提取代码特征向量 (极速)...")
    # 把代码拆解解成“词”，并计算它们的权重
    vectorizer = TfidfVectorizer(token_pattern=r'(?u)\b\w+\b') 
    tfidf_matrix = vectorizer.fit_transform(codes)
    
    print("⚡ 正在计算余弦相似度矩阵...")
    # 一次性算出所有文件相互之间的相似度！
    similarity_matrix = cosine_similarity(tfidf_matrix)
    
    results = []
    # 提取矩阵中的结果（只看上半区，因为 A对B 和 B对A 是一样的）
    for i in range(len(valid_files)):
        for j in range(i + 1, len(valid_files)):
            score = similarity_matrix[i][j]
            if score > 0.6: # 记录相似度大于 60% 的
                results.append({
                    'Contract A': valid_files[i],
                    'Contract B': valid_files[j],
                    'Similarity': round(score * 100, 2)
                })
    
    if results:
        # 排序并输出
        df = pd.DataFrame(results).sort_values(by='Similarity', ascending=False)
        print("\n🏆 --- 发现高度相似的合约对 (Top 20) ---")
        print(df.head(20).to_string(index=False))
        df.to_csv('fast_clone_report.csv', index=False)
        print(f"\n✅ 搞定！共找到 {len(results)} 对相似合约，耗时不到几秒吧？报告已保存至 fast_clone_report.csv")
    else:
        print("\n😭 惊了，这批合约的相似度竟然都低于 60%。")

if __name__ == "__main__":
    super_fast_detect()