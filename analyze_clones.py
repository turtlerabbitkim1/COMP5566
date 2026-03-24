import os
from difflib import SequenceMatcher
import pandas as pd # 如果报错，就在终端输入 pip install pandas

def calc_similarity(a, b):
    # SequenceMatcher 是 Python 内置的比较算法
    return SequenceMatcher(None, a, b).ratio()

def start_detecting():
    path = 'contracts'
    files = [f for f in os.listdir(path) if f.endswith('.sol')]
    
    print(f"🔍 正在深度比对 {len(files)} 个合约，请稍候...")
    
    results = []
    
    # 嵌套循环：让每个合约都和剩下的合约比一遍
    for i in range(len(files)):
        for j in range(i + 1, len(files)):
            file1 = files[i]
            file2 = files[j]
            
            with open(os.path.join(path, file1), 'r', encoding='utf-8', errors='ignore') as f1, \
                 open(os.path.join(path, file2), 'r', encoding='utf-8', errors='ignore') as f2:
                
                code1 = f1.read()
                code2 = f2.read()
                
                # 排除太小的文件干扰
                if len(code1) < 500 or len(code2) < 500:
                    continue
                    
                score = calc_similarity(code1, code2)
                
                # 只有相似度大于 60% 的我们才记录（这通常意味着存在抄袭或使用相同模板）
                if score > 0.6:
                    results.append({
                        'Contract A': file1,
                        'Contract B': file2,
                        'Similarity': round(score * 100, 2)
                    })
        
        # 每处理 10 个打印一下进度
        if (i + 1) % 10 == 0:
            print(f"已完成 {i+1}/{len(files)}...")

    # 将结果转成表格并排序
    if results:
        df = pd.DataFrame(results)
        df = df.sort_values(by='Similarity', ascending=False)
        
        print("\n🏆 --- 发现高度相似的合约对 ---")
        print(df.head(20).to_string(index=False)) # 打印前20名
        
        # 保存到 Excel 或 CSV，方便你直接贴到作业报告里
        df.to_csv('clone_report.csv', index=False)
        print("\n💾 详细报告已保存至: clone_report.csv")
    else:
        print("\n😅 奇了怪了，竟然没有发现相似度超过 60% 的合约。")

if __name__ == "__main__":
    # 如果没安装 pandas，先在终端运行: pip install pandas
    try:
        start_detecting()
    except ImportError:
        print("💡 请先在终端输入: pip install pandas")