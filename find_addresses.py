import requests
from bs4 import BeautifulSoup
import time

def get_latest_addresses():
    # Etherscan 已验证合约的页面
    url = "https://etherscan.io/contractsVerified"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
    }
    
    print("🔎 正在从 Etherscan 挖掘最新的已验证合约地址...")
    response = requests.get(url, headers=headers)
    
    if response.status_code == 200:
        soup = BeautifulSoup(response.text, 'html.parser')
        # 寻找页面上的合约地址链接
        links = soup.find_all('a', href=True)
        addresses = []
        for link in links:
            if link['href'].startswith('/address/0x'):
                addr = link['href'].split('/')[-1]
                if addr not in addresses:
                    addresses.append(addr)
        
        print(f"✅ 成功挖掘到 {len(addresses)} 个新地址！")
        
        # 把这些地址追加到你的 addresses.txt
        with open('addresses.txt', 'a') as f:
            for addr in addresses:
                f.write(addr + '\n')
        print("💾 地址已自动存入 addresses.txt")
    else:
        print("❌ 挖掘失败，可能被 Etherscan 暂时屏蔽了，等会儿再试。")

if __name__ == "__main__":
    get_latest_addresses()