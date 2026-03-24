import requests
import time
import os
import re

# --- 配置区 ---
API_KEY = '7GXKBNFEIUZ18APJ56BY932EVIVMNK7X2Z'  # 记得换成你的！
ADDRESS_FILE = 'addresses.txt'
SAVE_DIR = 'contracts'

if not os.path.exists(SAVE_DIR):
    os.makedirs(SAVE_DIR)

def sanitize_filename(name):
    """清理文件名，防止特殊字符导致保存失败"""
    return re.sub(r'[\\/*?:"<>|]', "", name)

def download_batch():
    with open(ADDRESS_FILE, 'r') as f:
        # 使用 set(集合) 自动去重，防止 400 个地址里有重复的
        addresses = list(set([line.strip().lower() for line in f if line.strip()]))

    total = len(addresses)
    print(f"📦 准备处理 {total} 个地址...")
    
    success_count = 0
    
    for i, addr in enumerate(addresses):
        # 1. 检查是否已经下载过（看文件名里有没有这个地址后缀）
        already_downloaded = any(addr[:6] in f for f in os.listdir(SAVE_DIR))
        if already_downloaded:
            # print(f"[{i+1}/{total}] 跳过已存在的: {addr}")
            success_count += 1
            continue

        url = f"https://api.etherscan.io/v2/api?chainid=1&module=contract&action=getsourcecode&address={addr}&apikey={API_KEY}"
        
        try:
            response = requests.get(url)
            data = response.json()
            
            if data['status'] == '1' and data['result'] and data['result'][0]['SourceCode']:
                raw_name = data['result'][0]['ContractName']
                name = sanitize_filename(raw_name)
                code = data['result'][0]['SourceCode']
                
                if len(code) > 200: # 过滤掉太短的无效代码
                    file_path = os.path.join(SAVE_DIR, f"{name}_{addr[:6]}.sol")
                    with open(file_path, 'w', encoding='utf-8') as f_out:
                        f_out.write(code)
                    success_count += 1
                    print(f"[{i+1}/{total}] ✅ 成功下载: {name}")
                else:
                    print(f"[{i+1}/{total}] ⏩ 代码太短，跳过")
            else:
                print(f"[{i+1}/{total}] ⏩ 未开源，跳过")
            
            # 遵守免费版每秒 5 次的限制，0.25秒是个安全值
            time.sleep(0.25) 
            
        except Exception as e:
            print(f"[{i+1}/{total}] ❌ 出错 {addr}: {e}")
            time.sleep(1) # 出错了歇一会儿

    print(f"\n✨ 全部处理完毕！成功收集了 {success_count} 个开源合约。")

if __name__ == "__main__":
    download_batch()