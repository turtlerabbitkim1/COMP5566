import requests
import time
import os
import re
import json
from tqdm import tqdm

# --- 配置区 ---
API_KEY = '7GXKBNFEIUZ18APJ56BY932EVIVMNK7X2Z'
ADDRESS_FILE = 'addresses.txt'
SAVE_DIR = 'contracts'

if not os.path.exists(SAVE_DIR):
    os.makedirs(SAVE_DIR)

def sanitize_filename(name):
    """清理文件名，防止特殊字符导致保存失败"""
    return re.sub(r'[\\/*?:"<>|]', "", name)

def save_source_code(addr, name, source_code):
    """
    保存源代码。支持处理 Etherscan 的多文件 JSON 格式。
    """
    name = sanitize_filename(name)
    # Etherscan 多文件格式通常以 {{ 开头
    if source_code.startswith('{{') and source_code.endswith('}}'):
        try:
            # 剥离外层大括号以获取标准 JSON
            json_str = source_code[1:-1]
            data = json.loads(json_str)
            sources = data.get('sources', {})
            combined_code = ""
            for file_path, content in sources.items():
                combined_code += f"// File: {file_path}\n{content['content']}\n\n"
            source_code = combined_code
        except Exception as e:
            print(f"解析多文件 JSON 出错 {addr}: {e}")
    
    if len(source_code) > 200:
        file_path = os.path.join(SAVE_DIR, f"{name}_{addr[:6]}.sol")
        with open(file_path, 'w', encoding='utf-8') as f_out:
            f_out.write(source_code)
        return True
    return False

def download_batch():
    if not os.path.exists(ADDRESS_FILE):
        print(f"❌ 找不到地址文件: {ADDRESS_FILE}")
        return

    with open(ADDRESS_FILE, 'r') as f:
        addresses = list(set([line.strip().lower() for line in f if line.strip()]))

    total = len(addresses)
    print(f"📦 准备处理 {total} 个地址...")
    
    success_count = 0
    # 使用 tqdm 展示美观的进度条
    pbar = tqdm(addresses, desc="下载进度", unit="addr")
    
    for addr in pbar:
        # 1. 检查是否已经下载过
        already_downloaded = any(addr[:6] in f for f in os.listdir(SAVE_DIR))
        if already_downloaded:
            success_count += 1
            continue

        url = f"https://api.etherscan.io/v2/api?chainid=1&module=contract&action=getsourcecode&address={addr}&apikey={API_KEY}"
        
        try:
            response = requests.get(url, timeout=10)
            if response.status_code != 200:
                continue
                
            data = response.json()
            if data['status'] == '1' and data['result'] and data['result'][0]['SourceCode']:
                raw_name = data['result'][0]['ContractName'] or "Unnamed"
                code = data['result'][0]['SourceCode']
                
                if save_source_code(addr, raw_name, code):
                    success_count += 1
                    pbar.set_postfix({"latest": raw_name[:10]})
            
            # 稍微增加延迟，确保 API 调用安全
            time.sleep(0.3) 
            
        except Exception as e:
            pbar.write(f"❌ 出错 {addr}: {e}")
            time.sleep(1)

    print(f"\n✨ 全部处理完毕！成功收集了 {success_count} 个开源合约。")

if __name__ == "__main__":
    download_batch()