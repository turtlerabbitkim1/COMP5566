import pandas as pd
import matplotlib.pyplot as plt
import os

def draw_bar_chart():
    csv_file = 'fast_clone_report.csv'
    if not os.path.exists(csv_file):
        print(f"❌ 找不到 {csv_file}")
        return

    # 读取数据
    df = pd.read_csv(csv_file)
    
    # 设定区间
    bins = [60, 70, 80, 90, 95, 100]
    labels = ['60%-70%\n(Weak Clone)', '70%-80%\n(Moderate)', '80%-90%\n(Strong)', '90%-95%\n(Very Strong)', '95%-100%\n(Exact/Near Exact)']
    
    # 将相似度分数分到对应的区间里，并统计数量
    df['Category'] = pd.cut(df['Similarity'], bins=bins, labels=labels, right=True)
    counts = df['Category'].value_counts().sort_index()

    # 开始画图
    plt.figure(figsize=(10, 6))
    bars = plt.bar(counts.index.astype(str), counts.values, color=['#a8e6cf', '#dcedc1', '#ffd3b6', '#ffaaa5', '#ff8b94'])
    
    # 在柱子上标上具体的数字
    for bar in bars:
        yval = bar.get_height()
        plt.text(bar.get_x() + bar.get_width()/2, yval + (max(counts.values)*0.01), int(yval), ha='center', va='bottom', fontsize=10, fontweight='bold')

    # 设置标题和标签
    plt.title('Distribution of Code Clones by Similarity Range', fontsize=16, pad=15)
    plt.xlabel('Similarity Range', fontsize=12)
    plt.ylabel('Number of Cloned Contract Pairs', fontsize=12)
    
    # 去除顶部和右侧的边框让图看起来更现代
    plt.gca().spines['top'].set_visible(False)
    plt.gca().spines['right'].set_visible(False)
    
    # 保存图片
    output_file = 'clone_distribution_bar.png'
    plt.savefig(output_file, bbox_inches='tight', dpi=150)
    print(f"📊 统计图已生成: {output_file}")
    # plt.show() # 如果想直接看图就取消注释

if __name__ == "__main__":
    draw_bar_chart()