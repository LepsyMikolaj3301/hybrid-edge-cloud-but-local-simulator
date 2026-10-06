FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && SP=/usr/local/lib/python3.11/site-packages \
 && find $SP -type d \( -name tests -o -name __pycache__ \) -prune -exec rm -rf {} + \
 && rm -rf $SP/numpy/f2py $SP/numpy/_core/include $SP/numpy/typing $SP/numpy/distutils $SP/numpy/_pyinstaller $SP/numpy/doc $SP/numpy/ma $SP/numpy/testing $SP/numpy/polynomial $SP/numpy/fft $SP/numpy/random \
 && find $SP -name "*.pyi" -delete
COPY window.py agg.py ./
RUN useradd -r -u 10001 agg
USER 10001
EXPOSE 8000
CMD ["python", "agg.py"]
